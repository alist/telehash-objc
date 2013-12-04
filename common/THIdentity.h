//
//  THIdentity.h
//  telehash
//
//  Created by Thomas Muldowney on 10/5/13.
//  Copyright (c) 2013 Telehash Foundation. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "RSA.h"

@interface THIdentity : NSObject

+(id)identityFromPublicKey:(NSString*)publicKeyPath privateKey:(NSString*)privateKeyPath;
+(id)identityFromPublicKey:(NSData*)key;
// Keys, hashname, address

-(id)initWithPublicKeyPath:(NSString*)publicKeyPath privateKey:(NSString*)privateKeyPath;
-(id)initWithPublicKey:(NSData*)key;

@property RSA* rsaKeys;
@property (readonly) NSString* hashname;
@property NSData* address;

// TODO:  Method to create a channel for a type

-(NSInteger)distanceFrom:(THIdentity*)identity;

@end

/*

TODO: Category for personal identity that allows for listening for a channel type

*/