//
//  MLOMEMO.m
//  Monal
//
//  Created by Friedrich Altheide on 21.06.20.
//  Copyright © 2020 Monal.im. All rights reserved.
//

#import "MLOMEMO.h"
#import "SignalAddress.h"
#import "MLSignalStore.h"
#import "SignalContext.h"
#import "AESGcm.h"
#import "HelperTools.h"
#import "XMPPIQ.h"
#import "xmpp.h"


@interface MLOMEMO ()

@property (atomic, strong) SignalContext* _signalContext;

// TODO: rename senderJID to accountJid
@property (nonatomic, strong) NSString* _senderJid;
@property (nonatomic, strong) NSString* _accountRessource;
@property (nonatomic, strong) NSString* _accountNo;
@property (nonatomic, strong) MLXMPPConnection* _connection;

@property (nonatomic, strong) xmpp* xmppConnection;

// jid -> @[deviceID1, deviceID2]
@property (nonatomic, strong) NSMutableDictionary* devicesWithBrokenSession;
@end

static const size_t MIN_OMEMO_KEYS = 25;
static const size_t MAX_OMEMO_KEYS = 120;

@implementation MLOMEMO

-(MLOMEMO *) initWithAccount:(NSString *) accountNo jid:(NSString *) jid ressource:(NSString*) ressource connectionProps:(MLXMPPConnection *) connectionProps xmppConnection:(xmpp*) xmppConnection
{
    self = [super init];
    self->signalLock = [NSLock new];
    self._senderJid = jid;
    self._accountRessource = ressource;
    self._accountNo = accountNo;
    self._connection = connectionProps;
    self.xmppConnection = xmppConnection;

    self.devicesWithBrokenSession = [[NSMutableDictionary alloc] init];

    [self setupSignal];

    [self.xmppConnection.pubsub registerInterestForNode:@"eu.siacs.conversations.axolotl.devicelist" withPersistentCaching:YES];
    
    return self;
}

-(void) setupSignal
{
    self.monalSignalStore = [[MLSignalStore alloc] initWithAccountId:self._accountNo];

    // signal store
    SignalStorage* signalStorage = [[SignalStorage alloc] initWithSignalStore:self.monalSignalStore];
    // signal context
    self._signalContext = [[SignalContext alloc] initWithStorage:signalStorage];
    // signal helper
    SignalKeyHelper* signalHelper = [[SignalKeyHelper alloc] initWithContext:self._signalContext];

    // init MLPubSub handler
    // TODO: register handler

    if(self.monalSignalStore.deviceid == 0)
    {
        // Generate a new device id
        // TODO: check if device id is unique
        self.monalSignalStore.deviceid = [signalHelper generateRegistrationId];
        // Create identity key pair
        self.monalSignalStore.identityKeyPair = [signalHelper generateIdentityKeyPair];
        self.monalSignalStore.signedPreKey = [signalHelper generateSignedPreKeyWithIdentity:self.monalSignalStore.identityKeyPair signedPreKeyId:1];
        // Generate single use keys
        [self generateNewKeysIfNeeded];
        [self sendOMEMOBundle];

        SignalAddress* address = [[SignalAddress alloc] initWithName:self._senderJid deviceId:self.monalSignalStore.deviceid];
        [self.monalSignalStore saveIdentity:address identityKey:self.monalSignalStore.identityKeyPair.publicKey];

        // request own omemo device list -> we will add our new device automatilcy as we are missing in the list
        [self queryOMEMODevicesFrom:self._senderJid];
        // FIXME: query queryOMEMODevicesFrom after connected -> state change
    }
}

-(void) sendOMEMOBundle
{
    [self publishKeysViaPubSub:@{@"signedPreKeyPublic":self.monalSignalStore.signedPreKey.keyPair.publicKey, @"signedPreKeySignature":self.monalSignalStore.signedPreKey.signature, @"identityKey":self.monalSignalStore.identityKeyPair.publicKey, @"signedPreKeyId": [NSString stringWithFormat:@"%d",self.monalSignalStore.signedPreKey.preKeyId]} andPreKeys:self.monalSignalStore.preKeys withDeviceId:self.monalSignalStore.deviceid];
}

-(void) queryOMEMODevicesFrom:(NSString *) jid
{
    if(!self._connection.supportsPubSub || (self.xmppConnection.accountState < kStateBound && ![self.xmppConnection isHibernated])) return;
    XMPPIQ* query = [[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqGetType];
    [query setiqTo:jid];
    [query requestDevices];
    if([jid isEqualToString:self._senderJid]) {
        // save our own last omemo query id for matching against our own device list received from the server
        self.deviceQueryId = [query.attributes objectForKey:@"id"];
    }

    if(self.xmppConnection) [self.xmppConnection send:query];
}

/*
 * generates new omemo keys if we have less than MIN_OMEMO_KEYS left
 */
-(void) generateNewKeysIfNeeded
{
    // generate new keys if less than MIN_OMEMO_KEYS are available
    int preKeyCount = [self.monalSignalStore getPreKeyCount];
    if(preKeyCount < MIN_OMEMO_KEYS) {
        SignalKeyHelper* signalHelper = [[SignalKeyHelper alloc] initWithContext:self._signalContext];

        // Generate new keys so that we have a total of MAX_OMEMO_KEYS keys again
        int lastPreyKedId = [self.monalSignalStore getHighestPreyKeyId];
        size_t cntKeysNeeded = MAX_OMEMO_KEYS - preKeyCount;
        // Start generating with keyId > last send key id
        self.monalSignalStore.preKeys = [signalHelper generatePreKeysWithStartingPreKeyId:(lastPreyKedId + 1) count:cntKeysNeeded];
        [self.monalSignalStore saveValues];

        // send out new omemo bundle
        [self sendOMEMOBundle];
    }
}

-(void) queryOMEMOBundleFrom:(NSString *) jid andDevice:(NSString *) deviceid
{
    if(!self._connection.supportsPubSub || (self.xmppConnection.accountState < kStateBound && ![self.xmppConnection isHibernated])) return;
    XMPPIQ* bundleQuery = [[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqGetType];
    [bundleQuery setiqTo:jid];
    [bundleQuery requestBundles:deviceid];

    if(self.xmppConnection) [self.xmppConnection send:bundleQuery];
}

-(void) processOMEMODevices:(NSSet<NSNumber*>*) receivedDevices from:(NSString *) source
{
    if(receivedDevices)
    {
        NSAssert([self._senderJid isEqualToString:self._connection.identity.jid], @"connection jid should be equal to the senderJid");

        NSArray<NSNumber*>* existingDevices = [self.monalSignalStore knownDevicesForAddressName:source];

        // query omemo bundles from devices that are not in our signalStorage
        // TODO: queryOMEMOBundleFrom when sending first msg without session
        for(NSNumber* deviceId in receivedDevices) {
            if(![existingDevices containsObject:deviceId]) {
                [self queryOMEMOBundleFrom:source andDevice:[deviceId stringValue]];
            }
        }
        // remove devices from our signalStorage when they are no longer published
        for(NSNumber* deviceId in existingDevices) {
            if(![receivedDevices containsObject:deviceId]) {
                // only delete other devices from signal store && keep our own entry
                if(!([source isEqualToString:self._senderJid] && deviceId.intValue == self.monalSignalStore.deviceid))
                    [self deleteDeviceForSource:source andRid:deviceId.intValue];
            }
        }
        // Send our own device id when it is missing on the server
        if(!source || [source isEqualToString:self._senderJid])
        {
            [self sendOMEMODevice:receivedDevices force:NO];
        }
    }
}

-(BOOL) knownDevicesForAddressNameExist:(NSString*) addressName
{
    return ([[self.monalSignalStore knownDevicesForAddressName:addressName] count] > 0);
}

-(NSArray<NSNumber*>*) knownDevicesForAddressName:(NSString*) addressName
{
    return [self.monalSignalStore knownDevicesForAddressName:addressName];
}

-(void) deleteDeviceForSource:(NSString*) source andRid:(int) rid
{
    SignalAddress* address = [[SignalAddress alloc] initWithName:source deviceId:rid];
    [self.monalSignalStore deleteDeviceforAddress:address];
}

-(BOOL) isTrustedIdentity:(SignalAddress*)address identityKey:(NSData*)identityKey
{
    return [self.monalSignalStore isTrustedIdentity:address identityKey:identityKey];
}

-(void) updateTrust:(BOOL) trust forAddress:(SignalAddress*)address
{
    [self.monalSignalStore updateTrust:trust forAddress:address];
}

-(NSData *) getIdentityForAddress:(SignalAddress*)address
{
    return [self.monalSignalStore getIdentityForAddress:address];
}



-(void) sendOMEMODeviceWithForce:(BOOL) force
{
    NSArray* ownCachedDevices = [self knownDevicesForAddressName:self._senderJid];
    NSSet<NSNumber*>* ownCachedDevicesSet = [[NSSet alloc] initWithArray:ownCachedDevices];
    [self sendOMEMODevice:ownCachedDevicesSet force:force];
}

-(void) sendOMEMODevice:(NSSet<NSNumber*>*) receivedDevices force:(BOOL) force
{
    NSMutableSet<NSNumber*>* devices = [[NSMutableSet alloc] init];
    if(receivedDevices && [receivedDevices count] > 0) {
        [devices unionSet:receivedDevices];
    }

    // Check if our own device string is already in our set
    if(![devices containsObject:[NSNumber numberWithInt:self.monalSignalStore.deviceid]] || force)
    {
        [devices addObject:[NSNumber numberWithInt:self.monalSignalStore.deviceid]];

        [self publishDevicesViaPubSub:devices];
    }
}

-(void) processOMEMOKeys:(XMPPIQ*) iqNode
{
    assert(self._signalContext);
    for(MLXMLNode* publishElement in [iqNode find:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.bundles:[0-9]+>"]) {
        NSString* bundleName = [publishElement findFirst:@"/@node"];
        if(!bundleName)
            return;
        // get rid
        NSString* rid = [bundleName componentsSeparatedByString:@":"][1];
        if(!rid)
            return;

        NSArray* bundles = [publishElement find:@"item/{eu.siacs.conversations.axolotl}bundle"];

        // there should only be one bundle per device
        if([bundles count] != 1) {
            return;
        }

        MLXMLNode* bundle = [bundles firstObject];

        // parse
        NSData* signedPreKeyPublic = [bundle findFirst:@"signedPreKeyPublic#|base64"];
        NSString* signedPreKeyPublicId = [bundle findFirst:@"signedPreKeyPublic@signedPreKeyId"];
        NSData* signedPreKeySignature = [bundle findFirst:@"signedPreKeySignature#|base64"];
        NSData* identityKey = [bundle findFirst:@"identityKey#|base64"];
        
        if(!signedPreKeyPublic || !signedPreKeyPublicId || !signedPreKeySignature || !identityKey)
            return;
        
        NSString* source = iqNode.fromUser;
        if(!source)
        {
            source = self._senderJid;
        }
        
        uint32_t device = (uint32_t)[rid intValue];
        SignalAddress* address = [[SignalAddress alloc] initWithName:source deviceId:device];
        SignalSessionBuilder* builder = [[SignalSessionBuilder alloc] initWithAddress:address context:self._signalContext];
        NSMutableArray* preKeys = [[NSMutableArray alloc] init];
        NSArray<NSNumber*>* preKeyIds = [bundle find:@"prekeys/preKeyPublic@preKeyId|int"];
        for(NSNumber* preKey in preKeyIds) {
            NSMutableDictionary* dict = [[NSMutableDictionary alloc] init];
            [dict setObject:preKey forKey:@"preKeyId"];
            NSString* query = [NSString stringWithFormat:@"prekeys/preKeyPublic<preKeyId=%@>#|base64", preKey.stringValue];
            [dict setObject:[bundle findFirst:query] forKey:@"preKey"];
            [preKeys addObject:dict];
        }
        // save preKeys to local storage
        for(NSDictionary* row in preKeys) {
            NSString* keyid = (NSString *)[row objectForKey:@"preKeyId"];
            NSData* preKeyData = [row objectForKey:@"preKey"];
            if(preKeyData) {
                //parallelize prekey bundle processing
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    DDLogDebug(@"Generating keyBundle for key id %@...", keyid);
                    SignalPreKeyBundle* keyBundle = [[SignalPreKeyBundle alloc] initWithRegistrationId:0
                                                                                    deviceId:device
                                                                                        preKeyId:[keyid intValue]
                                                                                    preKeyPublic:preKeyData
                                                                                    signedPreKeyId:signedPreKeyPublicId.intValue
                                                                                signedPreKeyPublic:signedPreKeyPublic
                                                                                        signature:signedPreKeySignature
                                                                                        identityKey:identityKey
                                                                                            error:nil];
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        NSError* error;
                        DDLogDebug(@"Processing keyBundle for key id %@...", keyid);
                        [builder processPreKeyBundle:keyBundle error:&error];
                        DDLogDebug(@"Done processing keyBundle for key id %@...", keyid);
                        if(error) {
                            DDLogWarn(@"Error creating preKeyBundle: %@", error);
                        }
                    });
                });
            } else  {
                DDLogError(@"Could not decode base64 prekey %@", row);
            }
        }
        // Build new session when a device session is marked as broken
        NSSet<NSNumber*>* devicesWithBrokenSession = [self.devicesWithBrokenSession objectForKey:source];
        if(devicesWithBrokenSession && [devicesWithBrokenSession containsObject:[NSNumber numberWithInt:[rid intValue]]]) {
            DDLogInfo(@"Fixing broken session for %@ deviceID: %@", source, rid);
            // FIXME: build new session
            // FIXME: only for trusted devices
        }
    }
}

-(void) addEncryptionKeyForAllDevices:(NSArray*) devices encryptForJid:(NSString*) encryptForJid withEncryptedPayload:(MLEncryptedPayload*) encryptedPayload withXMLHeader:(MLXMLNode*) xmlHeader {
    // Encrypt message for all devices known from the recipient
    for(NSNumber* device in devices) {
        SignalAddress* address = [[SignalAddress alloc] initWithName:encryptForJid deviceId:(uint32_t)device.intValue];

        NSData* identity = [self.monalSignalStore getIdentityForAddress:address];

        // Only add encryption key for devices that are trusted
        if([self.monalSignalStore isTrustedIdentity:address identityKey:identity]) {
            SignalSessionCipher* cipher = [[SignalSessionCipher alloc] initWithAddress:address context:self._signalContext];
            NSError* error;
            SignalCiphertext* deviceEncryptedKey = [cipher encryptData:encryptedPayload.key error:&error];

            MLXMLNode* keyNode = [[MLXMLNode alloc] initWithElement:@"key"];
            [keyNode.attributes setObject:[NSString stringWithFormat:@"%@", device] forKey:@"rid"];
            if(deviceEncryptedKey.type == SignalCiphertextTypePreKeyMessage)
            {
                [keyNode.attributes setObject:@"1" forKey:@"prekey"];
            }

            [keyNode setData:[HelperTools encodeBase64WithData:deviceEncryptedKey.data]];
            [xmlHeader.children addObject:keyNode];
        }
    }
}

// TODO: sendNewKeyTransport
-(void) sendNewKeyTransport:(NSString*) contact
{
    if(!self._connection.supportsPubSub || (self.xmppConnection.accountState < kStateBound && ![self.xmppConnection isHibernated])) return;

    XMPPMessage* messageNode = [[XMPPMessage alloc] init];
    [messageNode.attributes setObject:contact forKey:@"to"];
    [messageNode setXmppId:[[NSUUID UUID] UUIDString]];

    MLXMLNode* encrypted = [[MLXMLNode alloc] initWithElement:@"encrypted"];
    [encrypted.attributes setObject:@"eu.siacs.conversations.axolotl" forKey:kXMLNS];
    [messageNode.children addObject:encrypted];

    // Get own device id
    NSString* deviceid = [NSString stringWithFormat:@"%d", self.monalSignalStore.deviceid];
    MLXMLNode* header = [[MLXMLNode alloc] initWithElement:@"header"];
    [header.attributes setObject:deviceid forKey:@"sid"];
    [encrypted.children addObject:header];

    MLXMLNode* ivNode = [[MLXMLNode alloc] initWithElement:@"iv"];
    [ivNode setData:[HelperTools encodeBase64WithData:[AESGcm genIV]]];
    [header.children addObject:ivNode];

    NSArray* devices = [self.monalSignalStore allDeviceIdsForAddressName:contact];
    NSArray* myDevices = [self.monalSignalStore allDeviceIdsForAddressName:self._senderJid];

    // FIXME: encrypt for devices
    // [self addEncryptionKeyForAllDevices:devices encryptForJid:contact withEncryptedPayload:encryptedPayload withXMLHeader:header];

    // [self addEncryptionKeyForAllDevices:myDevices encryptForJid:self._senderJid withEncryptedPayload:encryptedPayload withXMLHeader:header];

    // Send
    if(self.xmppConnection) [self.xmppConnection send:messageNode];
}

-(void) encryptMessage:(XMPPMessage*) messageNode withMessage:(NSString*) message toContact:(NSString*) toContact
{
    NSAssert(self._signalContext, @"_signalContext should be inited.");

    [messageNode setBody:NSLocalizedString(@"[This message is OMEMO encrypted]", @"")];

    NSArray* devices = [self.monalSignalStore allDeviceIdsForAddressName:toContact];
    NSArray* myDevices = [self.monalSignalStore allDeviceIdsForAddressName:self._senderJid];

    // Check if we found omemo keys from the recipient
    if(devices.count > 0) {
        NSData* messageBytes = [message dataUsingEncoding:NSUTF8StringEncoding];

        // Encrypt message
        MLEncryptedPayload* encryptedPayload = [AESGcm encrypt:messageBytes keySize:16];

        MLXMLNode* encrypted = [[MLXMLNode alloc] initWithElement:@"encrypted"];
        [encrypted.attributes setObject:@"eu.siacs.conversations.axolotl" forKey:kXMLNS];
        [messageNode.children addObject:encrypted];

        MLXMLNode* payload = [[MLXMLNode alloc] initWithElement:@"payload"];
        [payload setData:[HelperTools encodeBase64WithData:encryptedPayload.body]];
        [encrypted.children addObject:payload];

        // Get own device id
        NSString* deviceid = [NSString stringWithFormat:@"%d", self.monalSignalStore.deviceid];
        MLXMLNode* header = [[MLXMLNode alloc] initWithElement:@"header"];
        [header.attributes setObject:deviceid forKey:@"sid"];
        [encrypted.children addObject:header];

        MLXMLNode* ivNode = [[MLXMLNode alloc] initWithElement:@"iv"];
        [ivNode setData:[HelperTools encodeBase64WithData:encryptedPayload.iv]];
        [header.children addObject:ivNode];

        [self addEncryptionKeyForAllDevices:devices encryptForJid:toContact withEncryptedPayload:encryptedPayload withXMLHeader:header];

        [self addEncryptionKeyForAllDevices:myDevices encryptForJid:self._senderJid withEncryptedPayload:encryptedPayload withXMLHeader:header];
    }
}

-(void) needNewSessionForContact:(NSString*) contact andDevice:(NSNumber*) deviceId
{
    // get set of broken device sessions for the given contact
    NSMutableSet<NSNumber*>* devicesWithInvalSession = [self.devicesWithBrokenSession objectForKey:contact];
    if(!devicesWithInvalSession) {
        // first broken session for contact -> create new set
        devicesWithInvalSession = [[NSMutableSet<NSNumber*> alloc] init];
    }
    // add device to broken session contact set
    [devicesWithInvalSession addObject:deviceId];
    [self.devicesWithBrokenSession setObject:devicesWithInvalSession forKey:contact];

    // delete broken session from our storage
    SignalAddress* address = [[SignalAddress alloc] initWithName:contact deviceId:(uint32_t)deviceId.intValue];
    [self.monalSignalStore deleteSessionRecordForAddress:address];

    // request device bundle again -> check for new preKeys
    // use received preKeys to build new session
    [self queryOMEMOBundleFrom:contact andDevice:deviceId.stringValue];
    // rebuild session when preKeys of the requested bundle arrived
}

-(NSString *) decryptMessage:(XMPPMessage *) messageNode
{
    if(![messageNode check:@"{eu.siacs.conversations.axolotl}encrypted/payload"]) {
        DDLogDebug(@"DecrypMessage called but the message is not encrypted");
        return nil;
    }

    [self->signalLock lock];

    NSNumber* sid = [messageNode findFirst:@"{eu.siacs.conversations.axolotl}encrypted/header@sid|int"];
    SignalAddress* address = [[SignalAddress alloc] initWithName:messageNode.fromUser deviceId:(uint32_t)sid.intValue];
    if(!self._signalContext) {
        DDLogError(@"Missing signal context");
        [self->signalLock unlock];
        return NSLocalizedString(@"Error decrypting message", @"");
    }

    NSString* deviceKeyPath = [NSString stringWithFormat:@"{eu.siacs.conversations.axolotl}encrypted/header/key<rid=%u>#|base64", self.monalSignalStore.deviceid];
    NSString* deviceKeyPathPreKey = [NSString stringWithFormat:@"{eu.siacs.conversations.axolotl}encrypted/header/key<rid=%u>@prekey|bool", self.monalSignalStore.deviceid];
    
    NSData* messageKey = [messageNode findFirst:deviceKeyPath];
    BOOL devicePreKey = [messageNode findFirst:deviceKeyPathPreKey];
    
    if(!messageKey)
    {
        DDLogError(@"Message was not encrypted for this device: %d", self.monalSignalStore.deviceid);
        [self->signalLock unlock];
        [self needNewSessionForContact:messageNode.fromUser andDevice:sid];
        return [NSString stringWithFormat:NSLocalizedString(@"Message was not encrypted for this device. Please make sure the sender trusts deviceid %d and that they have you as a contact.", @""), self.monalSignalStore.deviceid];
    } else {
        SignalSessionCipher* cipher = [[SignalSessionCipher alloc] initWithAddress:address context:self._signalContext];
        SignalCiphertextType messagetype;

        // Check if message is encrypted with a prekey
        if(devicePreKey)
        {
            messagetype = SignalCiphertextTypePreKeyMessage;
        } else  {
            messagetype = SignalCiphertextTypeMessage;
        }

        NSData* decoded = messageKey;

        SignalCiphertext* ciphertext = [[SignalCiphertext alloc] initWithData:decoded type:messagetype];
        NSError* error;
        NSData* decryptedKey = [cipher decryptCiphertext:ciphertext error:&error];
        if(error) {
            DDLogError(@"Could not decrypt to obtain key: %@", error);
            [self->signalLock unlock];
            [self needNewSessionForContact:messageNode.fromUser andDevice:sid];
            return [NSString stringWithFormat:@"There was an error decrypting this encrypted message (Signal error). To resolve this, try sending an encrypted message to this person. (%@)", error];
        }
        NSData* key;
        NSData* auth;

        if(messagetype == SignalCiphertextTypePreKeyMessage)
        {
            // check if we need to generate new preKeys
            [self generateNewKeysIfNeeded];
            // send new bundle without the used peyKey
            [self sendOMEMOBundle];
        }

        if(!decryptedKey){
            DDLogError(@"Could not decrypt to obtain key.");
            [self->signalLock unlock];
            [self needNewSessionForContact:messageNode.fromUser andDevice:sid];
            return NSLocalizedString(@"There was an error decrypting this encrypted message (Signal error). To resolve this, try sending an encrypted message to this person.", @"");
        }
        else  {
            if(decryptedKey.length == 16 * 2)
            {
                key = [decryptedKey subdataWithRange:NSMakeRange(0, 16)];
                auth = [decryptedKey subdataWithRange:NSMakeRange(16, 16)];
            }
            else {
                key = decryptedKey;
            }
            if(key){
                NSString* ivStr = [messageNode findFirst:@"{eu.siacs.conversations.axolotl}encrypted/header/iv#"];
                NSString* encryptedPayload = [messageNode findFirst:@"{eu.siacs.conversations.axolotl}encrypted/payload#"];

                NSData* iv = [HelperTools dataWithBase64EncodedString:ivStr];
                NSData* decodedPayload = [HelperTools dataWithBase64EncodedString:encryptedPayload];

                NSData* decData = [AESGcm decrypt:decodedPayload withKey:key andIv:iv withAuth:auth];
                if(!decData) {
                    DDLogError(@"Could not decrypt message with key that was decrypted.");
                    [self->signalLock unlock];
                     return NSLocalizedString(@"Encrypted message was sent in an older format Monal can't decrypt. Please ask them to update their client. (GCM error)", @"");
                }
                else  {
                    DDLogInfo(@"Decrypted message passing bask string.");
                }
                NSString* messageString = [[NSString alloc] initWithData:decData encoding:NSUTF8StringEncoding];
                [self->signalLock unlock];
                return messageString;
            } else  {
                DDLogError(@"Could not get key");
                [self->signalLock unlock];
                return NSLocalizedString(@"Could not decrypt message", @"");
            }
        }
    }
}


// create IQ messages
#pragma mark - signal
/**
 publishes a device.
 */
-(void) publishDevicesViaPubSub:(NSSet<NSNumber*>*) devices
{
    MLXMLNode* itemNode = [[MLXMLNode alloc] initWithElement:@"item"];
    [itemNode.attributes setObject:@"current" forKey:kId];

    MLXMLNode* listNode = [[MLXMLNode alloc] init];
    listNode.element=@"list";
    [listNode.attributes setObject:@"eu.siacs.conversations.axolotl" forKey:kXMLNS];

    for(NSNumber* deviceNum in devices) {
        NSString* deviceid = [deviceNum stringValue];
        MLXMLNode* device = [[MLXMLNode alloc] init];
        device.element = @"device";
        [device.attributes setObject:deviceid forKey:kId];
        [listNode addChild:device];
    }
    [itemNode addChild:listNode];

    // publish devices via pubsub
    [self.xmppConnection.pubsub publish:@[itemNode] onNode:@"eu.siacs.conversations.axolotl.devicelist"];
}

/**
 publishes signal keys and prekeys
 */
-(void) publishKeysViaPubSub:(NSDictionary *) keys andPreKeys:(NSArray *) prekeys withDeviceId:(u_int32_t) deviceid
{
    MLXMLNode* itemNode = [[MLXMLNode alloc] init];
    itemNode.element = @"item";
    [itemNode.attributes setObject:@"current" forKey:kId];

    MLXMLNode* bundle = [[MLXMLNode alloc] init];
    bundle.element = @"bundle";
    [bundle.attributes setObject:@"eu.siacs.conversations.axolotl" forKey:kXMLNS];

    MLXMLNode* signedPreKeyPublic = [[MLXMLNode alloc] init];
    signedPreKeyPublic.element = @"signedPreKeyPublic";
    [signedPreKeyPublic.attributes setObject:[keys objectForKey:@"signedPreKeyId"] forKey:@"signedPreKeyId"];
    signedPreKeyPublic.data = [HelperTools encodeBase64WithData: [keys objectForKey:@"signedPreKeyPublic"]];
    [bundle addChild:signedPreKeyPublic];

    MLXMLNode* signedPreKeySignature = [[MLXMLNode alloc] init];
    signedPreKeySignature.element = @"signedPreKeySignature";
    signedPreKeySignature.data = [HelperTools encodeBase64WithData:[keys objectForKey:@"signedPreKeySignature"]];
    [bundle addChild:signedPreKeySignature];

    MLXMLNode* identityKey = [[MLXMLNode alloc] init];
    identityKey.element = @"identityKey";
    identityKey.data = [HelperTools encodeBase64WithData:[keys objectForKey:@"identityKey"]];
    [bundle addChild:identityKey];

    MLXMLNode* prekeyNode = [[MLXMLNode alloc] init];
    prekeyNode.element = @"prekeys";

    for(SignalPreKey* prekey in prekeys) {
        MLXMLNode* preKeyPublic = [[MLXMLNode alloc] init];
        preKeyPublic.element = @"preKeyPublic";
        [preKeyPublic.attributes setObject:[NSString stringWithFormat:@"%d", prekey.preKeyId] forKey:@"preKeyId"];
        preKeyPublic.data = [HelperTools encodeBase64WithData:prekey.keyPair.publicKey];
        [prekeyNode addChild:preKeyPublic];
    };

    [bundle addChild:prekeyNode];
    [itemNode addChild:bundle];

    // send bundle via pubsub interface
    [self.xmppConnection.pubsub publish:@[itemNode] onNode:[NSString stringWithFormat:@"eu.siacs.conversations.axolotl.bundles:%u", deviceid]];
}

@end
