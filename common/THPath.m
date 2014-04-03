//
//  THPath.m
//  telehash
//
//  Created by Thomas Muldowney on 3/17/14.
//  Copyright (c) 2014 Telehash Foundation. All rights reserved.
//

#import "THPath.h"
#import "THPeerRelay.h"
#import "THSwitch.h"
#import "GCDAsyncUdpSocket.h"
#import "THPacket.h"
#include <arpa/inet.h>
#include <ifaddrs.h>

@implementation THPath

@end

@implementation THIPV4Path
{
    GCDAsyncUdpSocket* udpSocket;
    NSString* bindInterface;
    NSData* toAddress;
}

+(NSData*)addressTo:(NSString*)ip port:(NSUInteger)port
{
    struct sockaddr_in ipAddress;
    ipAddress.sin_len = sizeof(ipAddress);
    ipAddress.sin_family = AF_INET;
    ipAddress.sin_port = htons(port);
    inet_pton(AF_INET, [ip UTF8String], &ipAddress.sin_addr);
    return [NSData dataWithBytes:&ipAddress length:ipAddress.sin_len];
}

-(NSString*)typeName
{
    return @"ipv4";
}

-(id)init
{
    self = [super init];
    if (self) {
        udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    }
    return self;
}

-(id)initWithInterface:(NSString *)interface
{
    self = [self init];
    if (self) {
        bindInterface = interface;
    }
    return self;
}

-(id)initWithSocket:(GCDAsyncUdpSocket*)socket toAddress:(NSData*)address
{
    self = [super init];
    if (self) {
        udpSocket = socket;
        toAddress = address;
    }
    return self;
}

-(id)initWithSocket:(GCDAsyncUdpSocket *)socket ip:(NSString *)ip port:(NSUInteger)port
{
    // Only valid data please
    if (ip == nil || port == 0) return nil;
    
    self = [super init];
    if (self) {
        udpSocket = socket;

        
        struct sockaddr_in ipAddress;
        ipAddress.sin_len = sizeof(ipAddress);
        ipAddress.sin_family = AF_INET;
        ipAddress.sin_port = htons(port);
        inet_pton(AF_INET, [ip UTF8String], &ipAddress.sin_addr);
        toAddress = [NSData dataWithBytes:&ipAddress length:ipAddress.sin_len];
    }
    return self;
}

-(NSString*)ip
{
    return udpSocket.localHost_IPv4;
}

-(NSUInteger)port
{
    return udpSocket.localPort_IPv4;
}

-(THPath*)returnPathTo:(NSData*)address
{
    THIPV4Path* returnPath = [[THIPV4Path alloc] initWithSocket:udpSocket toAddress:address];
    return returnPath;
}

-(void)dealloc
{
    NSLog(@"Path go bye bye");
}

-(void)start;
{
    [self startOnPort:0];
}
-(void)startOnPort:(unsigned short)port
{
    NSError* bindError;
    if (bindInterface) {
        [udpSocket bindToPort:port interface:bindInterface error:&bindError];
    } else {
        [udpSocket bindToPort:port error:&bindError];
    }
    if (bindError != nil) {
        // TODO:  How do we show errors?!
        NSLog(@"%@", bindError);
        return;
    }
    NSLog(@"Now listening on %d", udpSocket.localPort);
    NSError* recvError;
    [udpSocket beginReceiving:&recvError];
    // TODO: Needs more error handling
}

-(void)sendPacket:(THPacket *)packet
{
    //TODO:  Evaluate using a timeout!
    NSData* packetData = [packet encode];
    //NSLog(@"Sending %@", packetData);
    [udpSocket sendData:packetData toAddress:toAddress withTimeout:-1 tag:0];
}

#pragma region -- UDP Handlers

-(void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext
{
    //NSLog(@"Incoming data from %@", [NSString stringWithUTF8String:inet_ntoa(addr->sin_addr)]);
    THPacket* incomingPacket = [THPacket packetData:data];
    incomingPacket.fromAddress = address;
    if (!incomingPacket) {
        NSString* host;
        uint16_t port;
        [GCDAsyncUdpSocket getHost:&host port:&port fromAddress:address];
        NSLog(@"Unexpected or unparseable packet from %@:%d: %@", host, port, [data base64EncodedStringWithOptions:0]);
        return;
    }
    
    incomingPacket.fromAddress = address;
    incomingPacket.path = self;

    if ([self.delegate respondsToSelector:@selector(handlePath:packet:)]) {
        [self.delegate handlePath:self packet:incomingPacket];
    }
}

-(void)udpSocket:(GCDAsyncUdpSocket *)sock didSendDataWithTag:(long)tag
{
    
}

-(NSDictionary*)information
{
    return @{
        @"type":self.typeName,
        @"ip":self.ip,
        @"port":@(self.port)
    };
}

-(NSDictionary*)informationTo:(NSData*)address
{
    NSString* ipRet;
    uint16_t port;
    
    [GCDAsyncUdpSocket getHost:&ipRet port:&port fromAddress:address];
    
    return @{
        @"type": self.typeName,
        @"ip":ipRet,
        @"port":@(port)
    };
}

+(NSArray*)gatherAvailableInterfacesApprovedBy:(THInterfaceApproverBlock)approver
{
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    // retrieve the current interfaces - returns 0 on success
    success = getifaddrs(&interfaces);
    if (success != 0) return nil;

    // Loop through linked list of interfaces
    temp_addr = interfaces;
    NSMutableArray* ret = [NSMutableArray array];
    while(temp_addr != NULL) {
        if(temp_addr->ifa_addr->sa_family == AF_INET) {
            NSString* interface = [NSString stringWithUTF8String:temp_addr->ifa_name];
            if (approver(interface)) {
                THIPV4Path* newPath = [[THIPV4Path alloc] initWithInterface:interface];
                [ret addObject:newPath];
            }
        }
        temp_addr = temp_addr->ifa_next;
    }
    
    // Free memory
    freeifaddrs(interfaces);
    
    return ret;
}

@end

@implementation THRelayPath
-(NSString*)typeName
{
    return @"relay";
}

-(void)sendPacket:(THPacket *)packet
{
    if (!self.peerChannel) return;
    
    THPacket* relayPacket = [THPacket new];
    relayPacket.body = [packet encode];
    
    NSLog(@"Relay sending %@", packet.json);
    [self.peerChannel sendPacket:relayPacket];
}

-(BOOL)channel:(THChannel *)channel handlePacket:(THPacket *)packet
{
    THPacket* relayedPacket = [THPacket packetData:packet.body];
    if ([self.delegate respondsToSelector:@selector(handlePath:packet:)]) {
        [self.delegate handlePath:self packet:relayedPacket];
    }
    
    return YES;
}

-(void)channel:(THChannel *)channel didFailWithError:(NSError *)error
{
    // XXX TODO: Shutdown the busted path
}

-(void)channel:(THChannel *)channel didChangeStateTo:(THChannelState)channelState
{
    // XXX TODO:  Shutdown on channel ended
}

-(NSDictionary*)information
{
    return nil;
}
@end