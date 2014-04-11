//
//  THAppDelegate.m
//  Telehash Playground
//
//  Created by Thomas Muldowney on 11/15/13.
//  Copyright (c) 2013 Telehash Foundation. All rights reserved.
//

#import "THAppDelegate.h"
#import "THIdentity.h"
#import <THPacket.h>
#import "THSwitch.h"
#import "THCipherSet.h"
#import "NSData+Hexstring.h"
#import "THTransport.h"
#import "THPath.h"

#include <arpa/inet.h>

#define SERVER_TEST 0

@interface THAppDelegate () {
    NSString* startChannelId;
}
@end

@implementation THAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [tableView setDataSource:self];
    
    // Insert code here to initialize your application
    thSwitch = [THSwitch defaultSwitch];
    thSwitch.delegate = self;
    THIdentity* baseIdentity = [THIdentity new];
    THCipherSet2a* cs2a = [[THCipherSet2a alloc] initWithPublicKeyPath:@"/tmp/telehash/server.pder" privateKeyPath:@"/tmp/telehash/server.der"];
    if (!cs2a) {
        NSFileManager* fm = [NSFileManager defaultManager];
        NSError* err;
        [fm createDirectoryAtPath:@"/tmp/telehash" withIntermediateDirectories:NO attributes:nil error:&err];
        THCipherSet2a* cs2a = [THCipherSet2a new];
        [cs2a generateKeys];
        [cs2a.rsaKeys savePublicKey:@"/tmp/telehash/server.pder" privateKey:@"/tmp/telehash/server.der"];
    }
    [baseIdentity addCipherSet:cs2a];
    NSLog(@"2a fingerprint %@", [cs2a.fingerprint hexString]);
    thSwitch.identity = baseIdentity;
    NSLog(@"Hashname: %@", [thSwitch.identity hashname]);
    THIPv4Transport* ipTransport = [THIPv4Transport new];
    [thSwitch addTransport:ipTransport];
    ipTransport.delegate = thSwitch;
    NSArray* paths = [ipTransport gatherAvailableInterfacesApprovedBy:^BOOL(NSString *interface) {
        if ([interface isEqualToString:@"lo0"]) return YES;
        if ([interface isEqualToString:@"en0"]) return YES;
        return NO;
    }];
    for (THIPV4Path* ipPath in paths) {
        [baseIdentity addPath:ipPath];
    }
    
    [thSwitch start];
    
    NSString* filePath = [[NSBundle mainBundle] pathForResource:@"seeds" ofType:@"json"];
    NSData* seedData = [NSData dataWithContentsOfFile:filePath];
    if (seedData) [thSwitch loadSeeds:seedData];

    //[thSwitch loadSeeds:[NSData dataWithContentsOfFile:@"/tmp/telehash/seeds.json"]];
}

-(NSInteger)numberOfRowsInTableView:(NSTableView *)tableView;
{
    return [thSwitch.openLines count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex;
{
    NSArray* keys = [thSwitch.openLines allKeys];
    THLine* line = [thSwitch.openLines objectForKey:[keys objectAtIndex:rowIndex]];
    return line.toIdentity.hashname;
}


-(void)openedLine:(THLine *)line;
{
    [tableView reloadData];
}

-(void)channelReady:(THChannel *)channel type:(THChannelType)type firstPacket:(THPacket *)packet;
{
    NSLog(@"Channel is ready");
    NSLog(@"First packet is %@", packet.json);
    return;
}

-(IBAction)connectToHashname:(id)sender
{
    THIdentity* connectToIdentity;
    NSString* key = [keyField stringValue];
    if (key.length > 0) {
/*
        NSData* keyData = [[NSData alloc] initWithBase64EncodedString:key options:0];
        connectToIdentity = [THIdentity identityFromPublicKey:keyData];
        NSString* address = [addressField stringValue];
        NSInteger port = [portField integerValue];
        if (address && port > 0) {
            [connectToIdentity setIP:address port:port];
        }
*/
    } else {
        connectToIdentity = [THIdentity identityFromHashname:[hashnameField stringValue]];
    }
    if (connectToIdentity) {
        [thSwitch openLine:connectToIdentity completion:^(THIdentity* openIdentity) {
            NSLog(@"We're in the app and connected to %@", connectToIdentity.hashname);
        }];
    }
}

-(void)thSwitch:(THSwitch *)thSwitch status:(THSwitchStatus)status
{
    NSLog(@"Switch status is now %d", status);
    if (status == THSwitchOnline) {
        THPacket* crapPacket = [THPacket new];
        [crapPacket.json setObject:@"crap" forKey:@"type"];
        
        THUnreliableChannel* chan = [[THUnreliableChannel alloc] initToIdentity:[THIdentity identityFromHashname:@"d3da6b886d827dd221f80ffefba99e800e0ce6d3b51f4eedb5373c9bbf9e5956"]];
        chan.delegate = self;
        
        [thSwitch openChannel:chan firstPacket:crapPacket];
    }
}

-(void)channel:(THChannel *)channel didFailWithError:(NSError *)error
{
    NSLog(@"Got an error: %@", error);
}
@end
