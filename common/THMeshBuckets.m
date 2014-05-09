//
//  THMeshBuckets.m
//  telehash
//
//  Created by Thomas Muldowney on 1/7/14.
//  Copyright (c) 2014 Telehash Foundation. All rights reserved.
//

#import "THMeshBuckets.h"
#import "THIdentity.h"
#import "THLine.h"
#import "THPacket.h"
#import "RNG.h"
#import "NSData+HexString.h"
#import "THSwitch.h"
#import "THPendingJob.h"
#import "THChannel.h"
#import "THPath.h"
#import "THUnreliableChannel.h"
#import "CLCLog.h"

#define K_BUCKET_SIZE 8
#define MAX_LINKS 256

@interface PendingSeekJob : NSObject<THChannelDelegate>
@property THIdentity* localIdentity;
@property THIdentity* seekingIdentity;
@property THSwitch* localSwitch;
@property NSMutableArray* nearby;
@property NSUInteger runningSearches;
@property (nonatomic, copy) SeekCompletionBlock completion;

-(void)runSeek;
-(BOOL)channel:(THChannel *)channel handlePacket:(THPacket *)packet;
@end

@implementation THMeshBuckets
{
    BOOL pendingPings;
    NSUInteger linkTotal;
}

-(id)init
{
    self = [super init];
    if (self) {
        self.buckets = [NSMutableArray arrayWithCapacity:256];
        for (int i = 0; i < 256; ++i) {
            [self.buckets insertObject:[NSMutableArray array] atIndex:i];
        }
    }
    return self;
}

-(void)pingLines
{
    time_t checkTime = time(NULL);
    [self.buckets enumerateObjectsUsingBlock:^(id obj, NSUInteger bucketIdx, BOOL *stop) {
        NSMutableArray* bucket = (NSMutableArray*)obj;
        [bucket enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            THIdentity* identity = (THIdentity*)obj;
            
            // Check for dead channels at 2m
            if (checkTime > identity.currentLine.lastInActivity + 120) {
				CLCLogWarning(@"line inactive for %@, removing link channel", identity.hashname);
                [bucket removeObjectAtIndex:idx];
                THChannel* channel = [identity channelForType:@"link"];
                if (channel) {
                    [identity.channels removeObjectForKey:channel.channelId];
                }
                // TODO:  Is the channel auto cleaned up properly now?  We dont' send an end:true because we assume it's dead
                return;
            }
            
            // 60s ping based on last activity
            //if (checkTime < identity.currentLine.lastOutActivity + 25) return;
            
            THPacket* pingPacket = [THPacket new];
            [pingPacket.json setObject:@YES forKey:@"seed"];
            
            THChannel* linkChannel = [identity channelForType:@"link"];
            if (linkChannel) [linkChannel sendPacket:pingPacket];
        }];
    }];
    
    if (!pendingPings) {
        double delayInSeconds = 25.0;
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            pendingPings = NO;
            [self pingLines];
        });
        pendingPings = YES;
    }
}

-(void)linkToIdentity:(THIdentity*)identity
{
    [self addIdentity:identity];
    THChannel* linkChannel = [identity channelForType:@"link"];
    THPacket* linkPacket = [THPacket new];
    [linkPacket.json setObject:@YES forKey:@"seed"]; // TODO:  Allow for opting out of seeding?
    
	NSArray* seeIdentities = [self nearby:identity];
    NSMutableArray* sees = [NSMutableArray array];
	
	if (seeIdentities != nil) {
		for (THIdentity* seeIdentity in seeIdentities) {
			[sees addObject:[seeIdentity seekStringForIdentity:identity]];
		}
	}
	
    [linkPacket.json setObject:sees forKey:@"see"];
    
    if (!linkChannel) {
        linkChannel = [[THUnreliableChannel alloc] initToIdentity:identity];
        [linkPacket.json setObject:@"link" forKey:@"type"];
        [[THSwitch defaultSwitch] openChannel:linkChannel firstPacket:linkPacket];
    } else {
        [linkChannel sendPacket:linkPacket];
    }
    linkChannel.delegate = self;
}

-(void)addIdentity:(THIdentity *)identity
{
    [self pingLines];
    
    NSInteger bucketIndex = [self.localIdentity distanceFrom:identity];
    NSMutableArray* bucket = [self.buckets objectAtIndex:bucketIndex];
    if (bucket == nil) {
        bucket = [NSMutableArray array];
    }
    
    THChannel* linkChannel = [identity channelForType:@"link"];
    // TODO:  Check our hints for age on this entry, if it's older we should bump the newest from the bucket if it's full
    if (linkTotal >= MAX_LINKS && bucket.count >= K_BUCKET_SIZE) {
        // TODO:  Evict the oldest
        
        if (linkChannel) {
            // TODO:  If we can not evict, we bail on it
            THPacket* endLinkPacket = [THPacket new];
            [endLinkPacket.json setObject:@YES forKey:@"end"];
            [endLinkPacket.json setObject:@NO forKey:@"seed"];
            [linkChannel sendPacket:endLinkPacket];
        }
        
        // TODO:  Check the cleanup on the channel and up the chain?
        return;
    }

    for (NSUInteger i = 0; i < bucket.count; ++i) {
        THIdentity* curIdentity = (THIdentity*)[bucket objectAtIndex:i];
        if ([curIdentity.hashname isEqualToString:identity.hashname]) {
            return;
        }
    }
    
    [bucket addObject:identity];
}

-(void)removeLine:(THLine *)line
{
    NSInteger bucketIndex = [self.localIdentity distanceFrom:line.toIdentity];
    [[self.buckets objectAtIndex:bucketIndex] removeObject:line];
}

-(NSArray*)closeInBucket:(THIdentity*)seekIdentity
{
    NSInteger bucketIndex = [self.localIdentity distanceFrom:seekIdentity];
    NSArray* bucket = [self.buckets objectAtIndex:bucketIndex];
    NSArray* results = [bucket sortedArrayUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSInteger hash1 = [seekIdentity distanceFrom:obj1];
        NSInteger hash2 = [seekIdentity distanceFrom:obj2];
        
        if (hash1 < hash2) {
            return NSOrderedDescending;
        } else if (hash2 > hash1) {
            return NSOrderedAscending;
        }
        
        return NSOrderedSame;
    }];
    return [results subarrayWithRange:NSMakeRange(0, MIN(5, results.count))];
}

-(NSArray*)nearby:(THIdentity*)seekIdentity;
{
    NSMutableArray* entries = [NSMutableArray array];
    NSInteger initialBucketIndex = [self.localIdentity distanceFrom:seekIdentity];
    // First get the closest
    [entries addObjectsFromArray:[self closeInBucket:seekIdentity]];
    // Go downwards for better matches
    NSInteger curBucketIndex = initialBucketIndex - 1;
    while (curBucketIndex >= 0 && [entries count] < 5) {
        NSArray* curBucket = [self.buckets objectAtIndex:curBucketIndex];
        if (curBucket.count == 0) {
            --curBucketIndex;
            continue;
        }
        [entries addObjectsFromArray:[curBucket subarrayWithRange:NSMakeRange(0, MIN(5 - entries.count, curBucket.count))]];
        --curBucketIndex;
    }
    // Now just make sure we're full with general entries
    curBucketIndex = initialBucketIndex + 1;
    while (curBucketIndex < 256) {
        NSArray* curBucket = [self.buckets objectAtIndex:curBucketIndex];
        if (curBucket.count == 0) {
            ++curBucketIndex;
            continue;
        }
        [entries addObjectsFromArray:[curBucket subarrayWithRange:NSMakeRange(0, MIN(5 - entries.count, curBucket.count))]];
        ++curBucketIndex;
    }
    return entries;
}

-(void)seek:(THIdentity*)toIdentity completion:(SeekCompletionBlock)completion
{
    CLCLogDebug(@"Seeking for %@", toIdentity.hashname);
    
    PendingSeekJob* seekJob = [PendingSeekJob new];
    seekJob.localSwitch = self.localSwitch;
    seekJob.localIdentity = self.localIdentity;
    seekJob.seekingIdentity = toIdentity;
    seekJob.completion = completion;
    NSArray* nearby = [self nearby:toIdentity];
    seekJob.nearby = [NSMutableArray arrayWithArray:[nearby subarrayWithRange:NSMakeRange(0, MIN(3, nearby.count))]];
    [self.pendingSeeks setValue:seekJob forKey:toIdentity.hashname];
    
    [seekJob.nearby enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        [seekJob runSeek];
    }];
    
}

// Channel delegate methods

-(BOOL)channel:(THChannel *)channel handlePacket:(THPacket *)packet
{
    THSwitch* defaultSwitch = [THSwitch defaultSwitch];
    if (defaultSwitch.status != THSwitchOnline) {
        [defaultSwitch updateStatus:THSwitchOnline];
    }
    
    THIPv4Transport* transport = [self.localSwitch.transports objectForKey:@"ipv4"];
    for (NSString* seeLine in [packet.json objectForKey:@"see"]) {
        NSArray* seeParts = [seeLine componentsSeparatedByString:@","];
        if (seeParts.count == 4) {
            if ([[seeParts objectAtIndex:0] isEqualToString:self.localIdentity.hashname]) continue;
            THIdentity* seeIdentity = [THIdentity identityFromHashname:[seeParts objectAtIndex:0]];
            NSInteger bucketIndex = [self.localIdentity distanceFrom:seeIdentity];
            NSMutableArray* bucket = [self.buckets objectAtIndex:bucketIndex];
            if (bucket == nil) {
                bucket = [NSMutableArray array];
            }
            
            // If we have a link channel already, just skip it
            THChannel* linkChannel = [seeIdentity channelForType:@"link"];
            if (linkChannel) continue;
            
            seeIdentity.suggestedCipherSet = [seeParts objectAtIndex:1];
            
            // TODO:  Check our hints for age on this entry, if it's older we should bump the newest from the bucket if it's full
            if (linkTotal >= MAX_LINKS || bucket.count >= K_BUCKET_SIZE) {
                break;
            }

            seeIdentity.via = channel.toIdentity;
            [seeIdentity addPath:[[THIPV4Path alloc] initWithTransport:transport ip:[seeParts objectAtIndex:2] port:[[seeParts objectAtIndex:3] integerValue]]];
            [self.localSwitch openLine:seeIdentity];
        }
    }
    
    NSUInteger now = time(NULL);
	
	// ensure we update the line lastInActivity so that we dont time it out within the pingLines method
	channel.line.lastInActivity = now;
	
    if (channel.lastOutActivity + 10 < now) {
        THPacket* pingPacket = [THPacket new];
        [pingPacket.json setObject:@YES forKey:@"seed"];
        if (channel.lastOutActivity == 0) {
            // Add the sees, it's our initial response
			NSArray* seeIdentities = [self nearby:channel.toIdentity];
			NSMutableArray* sees = [NSMutableArray array];
			
			if (seeIdentities != nil) {
				for (THIdentity* seeIdentity in seeIdentities) {
					[sees addObject:[seeIdentity seekStringForIdentity:channel.toIdentity]];
				}
			}
			
            [pingPacket.json setObject:sees forKey:@"see"];
        }
        [channel sendPacket:pingPacket];
    }
    
    return YES;
}

-(void)channel:(THChannel *)channel didChangeStateTo:(THChannelState)channelState
{
    if (channelState == THChannelEnded || channelState == THChannelErrored) {
		CLCLogWarning(@"link channel ended");
        NSMutableArray* bucket = [self.buckets objectAtIndex:[self.localIdentity distanceFrom:channel.toIdentity]];
        [bucket removeObject:channel];
    }
}

-(void)channel:(THChannel *)channel didFailWithError:(NSError *)error
{
	CLCLogWarning(@"link channel errored with error: %@", [error description]);
    NSMutableArray* bucket = [self.buckets objectAtIndex:[self.localIdentity distanceFrom:channel.toIdentity]];
    [bucket removeObject:channel];
}
@end


@implementation PendingSeekJob
-(void)runSeek
{
    if (self.nearby.count == 0) return;
    
    // Resort and run the seek
    THIdentity* identity = [self.nearby objectAtIndex:0];
    [self.nearby removeObjectAtIndex:0];
    
    THSwitch* defaultSwitch = [THSwitch defaultSwitch];
    ++self.runningSearches;
    
    THChannel* seekChannel = [[THUnreliableChannel alloc] initToIdentity:identity];
    seekChannel.delegate = self;
    
    THPacket* seekPacket = [THPacket new];
    [seekPacket.json setObject:self.seekingIdentity.hashname forKey:@"seek"];
    [seekPacket.json setObject:@"seek" forKey:@"type"];
    
    [defaultSwitch openChannel:seekChannel firstPacket:seekPacket];
}

 -(BOOL)channel:(THChannel*)channel handlePacket:(THPacket*)packet
{
     
    NSString* error = [packet.json objectForKey:@"err"];
    if (error) return YES;

    NSArray* sees = [packet.json objectForKey:@"see"];
    __block BOOL foundIt = NO;
    CLCLogDebug(@"Checking for %@ in sees %@",  self.seekingIdentity.hashname, sees);
    [sees enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSString* seeString = (NSString*)obj;
        NSArray* seeParts = [seeString componentsSeparatedByString:@","];
        if (seeParts.count < 2) {
            CLCLogDebug(@"Invalid see parts: %@", seeParts);
            return;
        }
        if ([[seeParts objectAtIndex:0] isEqualToString:self.seekingIdentity.hashname]) {
			CLCLogDebug(@"We found %@!", self.seekingIdentity.hashname);
			// this is it!
			self.seekingIdentity.via = channel.toIdentity;
			self.seekingIdentity.suggestedCipherSet = [seeParts objectAtIndex:1];
			
			if (seeParts.count > 2) {
				THIPv4Transport* localTransport = [self.localSwitch.transports objectForKey:@"ipv4"];
				if (localTransport) {
					NSData* remoteAddress = [THIPV4Path addressTo:[seeParts objectAtIndex:2] port:[[seeParts objectAtIndex:3] integerValue]];
					[self.seekingIdentity addPath:[localTransport returnPathTo:remoteAddress]];
				}
			}
			foundIt = YES;
			*stop = YES;
			return;
			
        } else {
            // If they told us to ask ourself ignore it
            if ([[seeParts objectAtIndex:0] isEqualToString:self.localIdentity.hashname]) return;
			
            // If we're moving closer we want to go ahead and start a seek to it
            THIdentity* nearIdentity = [THIdentity identityFromHashname:[seeParts objectAtIndex:0]];
            nearIdentity.via = channel.toIdentity;
			nearIdentity.suggestedCipherSet = [seeParts objectAtIndex:1];
            [self.nearby addObject:nearIdentity];
        }
    }];
    
    if (foundIt) {
        if (self.completion) self.completion(YES);
        return YES;
    }
     
    // Sort on distance and run again
    [self.nearby sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        NSInteger hash1 = [self.seekingIdentity distanceFrom:obj1];
        NSInteger hash2 = [self.seekingIdentity distanceFrom:obj2];
         
        if (hash1 < hash2) {
            return NSOrderedDescending;
        } else if (hash2 > hash1) {
            return NSOrderedAscending;
        }
         
        return NSOrderedSame;
    }];
     
    if (self.nearby.count > 0) {
        [self runSeek];
        for (NSUInteger i = self.runningSearches; i < MIN(3, self.nearby.count - 1); ++i) {
            [self runSeek];
        }
    }
     
    return YES;
}

@end
