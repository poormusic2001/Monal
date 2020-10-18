//
//  MLOMEMO.h
//  Monal
//
//  Created by Friedrich Altheide on 21.06.20.
//  Copyright © 2020 Monal.im. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MLXMPPConnection.h"
#import "xmpp.h"
#import "XMPPMessage.h"
#import "MLSignalStore.h"

NS_ASSUME_NONNULL_BEGIN

@class xmpp;
@class XMPPIQ;

@interface MLOMEMO : NSObject {
    NSLock* signalLock;
}
@property (nonatomic, strong) MLSignalStore* monalSignalStore;
@property (nonatomic, strong) NSString* deviceQueryId;

-(MLOMEMO *) initWithAccount:(NSString *) accountNo jid:(NSString *) jid ressource:(NSString*) ressource connectionProps:(MLXMPPConnection *) connectionProps xmppConnection:(xmpp*) xmppConnection;

/*
 * handle omemo iq's
 */
-(void) sendOMEMOBundle;
-(void) queryOMEMODevicesFrom:(NSString *) jid;
-(void) queryOMEMOBundleFrom:(NSString *) jid andDevice:(NSString *) deviceid;
-(void) sendOMEMODeviceWithForce:(BOOL) force;
-(void) sendOMEMODevice:(NSSet<NSNumber*> *) receivedDevices force:(BOOL) force;
-(void) processOMEMODevices:(NSSet<NSNumber*>*) receivedDevices from:(NSString *) source;
-(void) processOMEMOKeys:(XMPPIQ*) iqNode;

/*
 * encrypting / decrypting messages
 */
-(void) encryptMessage:(XMPPMessage*) messageNode withMessage:(NSString* _Nullable) message toContact:(NSString*) toContact;
-(NSString *) decryptMessage:(XMPPMessage *) messageNode;


-(BOOL) knownDevicesForAddressNameExist:(NSString*) addressName;
-(NSArray<NSNumber*>*) knownDevicesForAddressName:(NSString*) addressName;

-(void) deleteDeviceForSource:(NSString*) source andRid:(int) rid;
-(BOOL) isTrustedIdentity:(SignalAddress*)address identityKey:(NSData*)identityKey;
-(void) updateTrust:(BOOL) trust forAddress:(SignalAddress*)address;
-(NSData *) getIdentityForAddress:(SignalAddress*)address;


@end

NS_ASSUME_NONNULL_END
