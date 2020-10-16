//
//  MLIQProcessor.m
//  Monal
//
//  Created by Anurodh Pokharel on 11/27/19.
//  Copyright © 2019 Monal.im. All rights reserved.
//

#import "MLIQProcessor.h"
#import "MLConstants.h"
#import "DataLayer.h"
#import "MLImageManager.h"
#import "HelperTools.h"
#import "MLOMEMO.h"

@class MLOMEMO;

@interface MLIQProcessor()

@end

/**
 Validate and process any iq elements.
 @link https://xmpp.org/rfcs/rfc6120.html#stanzas-semantics-iq
 */
@implementation MLIQProcessor

+(void) processIq:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:kiqGetType])
        [self processGetIq:iqNode forAccount:account];
    else if([[iqNode findFirst:@"/@type"] isEqualToString:kiqSetType])
        [self processSetIq:iqNode forAccount:account];
    else if([[iqNode findFirst:@"/@type"] isEqualToString:kiqResultType])
        [self processResultIq:iqNode forAccount:account];
    else if([[iqNode findFirst:@"/@type"] isEqualToString:kiqErrorType])
        [self processErrorIq:iqNode forAccount:account];
    else
        DDLogWarn(@"Ignoring invalid iq type: %@", [iqNode findFirst:@"/@type"]);
}

+(void) processGetIq:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
    if([iqNode check:@"{urn:xmpp:ping}ping"])
    {
        XMPPIQ* pong = [[XMPPIQ alloc] initWithId:[iqNode findFirst:@"/@id"] andType:kiqResultType];
        [pong setiqTo:iqNode.from];
        [account send:pong];
    }
    
    if([iqNode check:@"{jabber:iq:version}query"])
    {
        XMPPIQ* versioniq = [[XMPPIQ alloc] initWithId:[iqNode findFirst:@"/@id"] andType:kiqResultType];
        [versioniq setiqTo:iqNode.from];
        [versioniq setVersion];
        [account send:versioniq];
    }
    
    if([iqNode check:@"{http://jabber.org/protocol/disco#info}query"])
    {
        XMPPIQ* discoInfoResponse = [[XMPPIQ alloc] initAsResponseTo:iqNode withType:kiqResultType];
        [discoInfoResponse setDiscoInfoWithFeatures:account.capsFeatures identity:account.capsIdentity andNode:[iqNode findFirst:@"{http://jabber.org/protocol/disco#info}query@node"]];
        [account send:discoInfoResponse];
    }
}

+(void) processSetIq:(XMPPIQ *) iqNode forAccount:(xmpp*) account
{
    //its a roster push (sanity check will be done in handleRosterFor:withIqNode)
    if([iqNode check:@"{jabber:iq:roster}query"])
    {
        [self handleRosterFor:account withIqNode:iqNode];
        
        //send empty result iq as per RFC 6121 requirements
        XMPPIQ* reply = [[XMPPIQ alloc] initWithId:[iqNode findFirst:@"/@id"] andType:kiqResultType];
        [reply setiqTo:iqNode.from];
        [account send:reply];
    }
}

+(void) processResultIq:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
    if([iqNode check:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.bundles:[0-9]+>"] ||
       [iqNode check:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.devicelist>"]) {
        [self omemoResult:iqNode forAccount:account];
    }
    
    if([iqNode check:@"{jabber:iq:version}query"])
        [self iqVersionResult:iqNode forAccount:account];
}

+(void) processErrorIq:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
    DDLogWarn(@"Got unhandled IQ error: %@", iqNode);
}

+(void) postError:(NSString*) description withIqNode:(XMPPIQ*) iqNode andAccount:(xmpp*) account
{
    NSString* errorReason = [iqNode findFirst:@"{urn:ietf:params:xml:ns:xmpp-stanzas}!text$"];
    NSString* errorText = [iqNode findFirst:@"{urn:ietf:params:xml:ns:xmpp-stanzas}text#"];
    NSString* message = [NSString stringWithFormat:@"%@: %@", description, errorReason];
    if(errorText && ![errorText isEqualToString:@""])
        message = [NSString stringWithFormat:@"%@ %@: %@", description, errorReason, errorText];
    [[NSNotificationCenter defaultCenter] postNotificationName:kXMPPError object:@[account, message]];
}

+(void) handleCatchupFor:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogWarn(@"Mam catchup query returned error: %@", [iqNode findFirst:@"error"]);
        [account mamFinished];
        return;
    }
    if(![iqNode findFirst:@"{urn:xmpp:mam:2}fin@complete|bool"] && [iqNode check:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"])
    {
        DDLogVerbose(@"Paging through mam catchup results with after: %@", [iqNode findFirst:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"]);
        //do RSM forward paging
        XMPPIQ* pageQuery = [[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqSetType];
        [pageQuery setMAMQueryAfter:[iqNode findFirst:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"]];
        [account sendIq:pageQuery withDelegate:self andMethod:@selector(handleCatchupFor:withIqNode:) andAdditionalArguments:nil];
    }
    else if([iqNode findFirst:@"{urn:xmpp:mam:2}fin@complete|bool"])
    {
        DDLogVerbose(@"Mam catchup finished");
        [account mamFinished];
    }
}

+(void) handleMamResponseWithLatestIdFor:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    DDLogVerbose(@"Got latest stanza id to prime database with: %@", [iqNode findFirst:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"]);
    //only do this if we got a valid stanza id (not null)
    //if we did not get one we will get one when receiving the next message in this smacks session
    //if the smacks session times out before we get a message and someone sends us one or more messages before we had a chance to establish
    //a new smacks session, this messages will get lost because we don't know how to query the archive for this message yet
    //once we successfully receive the first mam-archived message stanza (could even be an XEP-184 ack for a sent message),
    //no more messages will get lost
    //we ignore this single message loss here, because it should be super rare and solving it would be really complicated
    if([iqNode check:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"])
        [[DataLayer sharedInstance] setLastStanzaId:[iqNode findFirst:@"{urn:xmpp:mam:2}fin/{http://jabber.org/protocol/rsm}set/last#"] forAccount:account.accountNo];
    [account mamFinished];
}

+(void) handleCarbonsEnabledFor:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogWarn(@"carbon enable iq returned error: %@", [iqNode findFirst:@"error"]);
        return;
    }
    account.connectionProperties.usingCarbons2 = YES;
}

+(void) handleBindFor:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogWarn(@"Binding our resource returned an error: %@", [iqNode findFirst:@"error"]);
        if([@"cancel" isEqualToString:[iqNode findFirst:@"/@type"]])
        {
            [self postError:@"XMPP Bind Error" withIqNode:iqNode andAccount:account];
            [account disconnect];
        }
        else if([@"modify" isEqualToString:[iqNode findFirst:@"/@type"]])
            [account bindResource:[HelperTools encodeRandomResource]];      //try to bind a new resource
        else
            [account reconnect];        //just try to reconnect (wait error type and all other error types not expected for bind)
        return;
    }
    
    DDLogInfo(@"Binding to jid: %@", [iqNode findFirst:@"{urn:ietf:params:xml:ns:xmpp-bind}bind/jid#"]);
    [account.connectionProperties.identity bindJid:[iqNode findFirst:@"{urn:ietf:params:xml:ns:xmpp-bind}bind/jid#"]];
    DDLogDebug(@"After bind: jid=%@, resource=%@, fullJid=%@", account.connectionProperties.identity.jid, account.connectionProperties.identity.resource, account.connectionProperties.identity.fullJid);
    
    //update resource in db (could be changed by server)
    NSMutableDictionary* accountDict = [[NSMutableDictionary alloc] initWithDictionary:[[DataLayer sharedInstance] detailsForAccount:account.accountNo]];
    accountDict[kResource] = account.connectionProperties.identity.resource;
    [[DataLayer sharedInstance] updateAccounWithDictionary:accountDict];
    
    if(account.connectionProperties.supportsSM3)
    {
        MLXMLNode *enableNode = [[MLXMLNode alloc]
            initWithElement:@"enable"
            andNamespace:@"urn:xmpp:sm:3"
            withAttributes:@{@"resume": @"true"}
            andChildren:@[]
            andData:nil
        ];
        [account send:enableNode];
    }
    else
    {
        //init session and query disco, roster etc.
        [account initSession];
    }
}

+(void) handleRosterFor:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    //check sanity of from according to RFC 6121:
    //  https://tools.ietf.org/html/rfc6121#section-2.1.3 (roster get)
    //  https://tools.ietf.org/html/rfc6121#section-2.1.6 (roster push)
    if(
        iqNode.from != nil &&
        ![iqNode.from isEqualToString:account.connectionProperties.identity.jid] &&
        ![iqNode.from isEqualToString:account.connectionProperties.identity.domain]
    )
    {
        DDLogWarn(@"Invalid sender for roster, ignoring iq: %@", iqNode);
        return;
    }
    
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogWarn(@"Roster query returned an error: %@", [iqNode findFirst:@"error"]);
        [self postError:@"XMPP Roster Error" withIqNode:iqNode andAccount:account];
        return;
    }
    
    for(NSDictionary* contact in [iqNode find:@"{jabber:iq:roster}query/item@@"])
    {
        if([[contact objectForKey:@"subscription"] isEqualToString:kSubRemove])
        {
            [[DataLayer sharedInstance] removeBuddy:[contact objectForKey:@"jid"] forAccount:account.accountNo];
        }
        else
        {
            MLContact* contactObj = [[MLContact alloc] init];
            contactObj.contactJid = [contact objectForKey:@"jid"];
            contactObj.accountId = account.accountNo;

            if([[contact objectForKey:@"subscription"] isEqualToString:kSubTo])
            {
                [[DataLayer sharedInstance] addContactRequest:contactObj];
            }
            else if([[contact objectForKey:@"subscription"] isEqualToString:kSubFrom]) //already subscribed
            {
                [[DataLayer sharedInstance] deleteContactRequest:contactObj];
            }
            else if([[contact objectForKey:@"subscription"] isEqualToString:kSubBoth])
            {
                // We and the contact are interested
                [[DataLayer sharedInstance] deleteContactRequest:contactObj];
            }

            
            DDLogVerbose(@"Adding contact %@ (%@) to database", [contact objectForKey:@"jid"], [contact objectForKey:@"name"]);
            BOOL success = [[DataLayer sharedInstance] addContact:[contact objectForKey:@"jid"]
                                        forAccount:account.accountNo
                                          fullname:[contact objectForKey:@"name"]?[contact objectForKey:@"name"]:@""
                                          nickname:[contact objectForKey:@"name"]?[contact objectForKey:@"name"]:@""
                                                       andMucNick:nil];
                
            [[DataLayer sharedInstance] setSubscription:[contact objectForKey:@"subscription"]
                                                 andAsk:[contact objectForKey:@"ask"] forContact:[contact objectForKey:@"jid"] andAccount:account.accountNo];
            
            if(!success && ((NSString *)[contact objectForKey:@"name"]).length>0)
            {
                [[DataLayer sharedInstance] setFullName:[contact objectForKey:@"name"] forContact:[contact objectForKey:@"jid"] andAccount:account.accountNo ] ;
            }
        }
    }
    
    if([iqNode check:@"{jabber:iq:roster}query@ver"])
        [[DataLayer sharedInstance] setRosterVersion:[iqNode findFirst:@"{jabber:iq:roster}query@ver"] forAccount:account.accountNo];
}

//features advertised on our own jid/account
+(void) handleAccountDiscoInfo:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogError(@"Disco info query to our account returned an error: %@", [iqNode findFirst:@"error"]);
        [self postError:@"XMPP Account Info Error" withIqNode:iqNode andAccount:account];
        return;
    }
    
    NSSet* features = [NSSet setWithArray:[iqNode find:@"{http://jabber.org/protocol/disco#info}query/feature@var"]];
    
    if(
        [iqNode check:@"{http://jabber.org/protocol/disco#info}query/identity<category=pubsub><type=pep>"] &&       //xep-0163 support
        [features containsObject:@"http://jabber.org/protocol/pubsub#publish"] &&                                   //xep-0060 support
        [features containsObject:@"http://jabber.org/protocol/pubsub#filtered-notifications"] &&                    //xep-0163 support
        [features containsObject:@"http://jabber.org/protocol/pubsub#publish-options"]                              //xep-0223 support
    )
        account.connectionProperties.supportsPubSub = YES;
    
    if([features containsObject:@"urn:xmpp:push:0"])
    {
        account.connectionProperties.supportsPush = YES;
        [account enablePush];
    }
    
    if([features containsObject:@"urn:xmpp:mam:2"])
    {
        account.connectionProperties.supportsMam2 = YES;
        DDLogInfo(@"supports mam:2");
        
        //query mam since last received stanza ID because we could not resume the smacks session
        //(we would not have landed here if we were able to resume the smacks session)
        //this will do a catchup of everything we might have missed since our last connection
        //we possibly receive sent messages, too (this will update the stanzaid in database and gets deduplicate by messageid,
        //which is guaranteed to be unique (because monal uses uuids for outgoing messages)
        NSString* lastStanzaId = [[DataLayer sharedInstance] lastStanzaIdForAccount:account.accountNo];
        XMPPIQ* mamQuery = [[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqSetType];
        if(lastStanzaId)
        {
            DDLogInfo(@"Querying mam:2 archive after stanzaid '%@' for catchup", lastStanzaId);
            [mamQuery setMAMQueryAfter:lastStanzaId];
            [account sendIq:mamQuery withDelegate:self andMethod:@selector(handleCatchupFor:withIqNode:) andAdditionalArguments:nil];
        }
        else
        {
            DDLogInfo(@"Querying mam:2 archive for latest stanzaid to prime database");
            [mamQuery setMAMQueryForLatestId];
            [account sendIq:mamQuery withDelegate:self andMethod:@selector(handleMamResponseWithLatestIdFor:withIqNode:) andAdditionalArguments:nil];
        }
    }
}

//features advertised on our server
+(void) handleServerDiscoInfo:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    if([[iqNode findFirst:@"/@type"] isEqualToString:@"error"])
    {
        DDLogError(@"Disco info query to our server returned an error: %@", [iqNode findFirst:@"error"]);
        [self postError:@"XMPP Disco Info Error" withIqNode:iqNode andAccount:account];
        return;
    }
    
    NSSet* features = [NSSet setWithArray:[iqNode find:@"{http://jabber.org/protocol/disco#info}query/feature@var"]];
    account.connectionProperties.serverFeatures = features;
    
    if([features containsObject:@"urn:xmpp:carbons:2"])
    {
        DDLogInfo(@"got disco result with carbons ns");
        if(!account.connectionProperties.usingCarbons2)
        {
            DDLogInfo(@"enabling carbons");
            XMPPIQ* carbons = [[XMPPIQ alloc] initWithType:kiqSetType];
            [carbons addChild:[[MLXMLNode alloc] initWithElement:@"enable" andNamespace:@"urn:xmpp:carbons:2"]];
            [account sendIq:carbons withDelegate:self andMethod:@selector(handleCarbonsEnabledFor:withIqNode:) andAdditionalArguments:nil];
        }
    }
    
    if([features containsObject:@"urn:xmpp:ping"])
        account.connectionProperties.supportsPing = YES;
    
    if([features containsObject:@"urn:xmpp:blocking"])
        account.connectionProperties.supportsBlocking=YES;
}

+(void) handleServiceDiscoInfo:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    NSSet* features = [NSSet setWithArray:[iqNode find:@"{http://jabber.org/protocol/disco#info}query/feature@var"]];
    
    if(!account.connectionProperties.supportsHTTPUpload && [features containsObject:@"urn:xmpp:http:upload:0"])
    {
        DDLogInfo(@"supports http upload with server: %@", iqNode.from);
        account.connectionProperties.supportsHTTPUpload = YES;
        account.connectionProperties.uploadServer = iqNode.from;
    }
    
    if(!account.connectionProperties.conferenceServer && [features containsObject:@"http://jabber.org/protocol/muc"])
        account.connectionProperties.conferenceServer = iqNode.from;
}

+(void) handleServerDiscoItems:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    account.connectionProperties.discoveredServices = [[NSMutableArray alloc] init];
    for(NSDictionary* item in [iqNode find:@"{http://jabber.org/protocol/disco#items}query/item@@"])
    {
        [account.connectionProperties.discoveredServices addObject:item];
        if(![[item objectForKey:@"jid"] isEqualToString:account.connectionProperties.identity.domain])
        {
            XMPPIQ* discoInfo = [[XMPPIQ alloc] initWithType:kiqGetType];
            [discoInfo setiqTo:[item objectForKey:@"jid"]];
            [discoInfo setDiscoInfoNode];
            [account sendIq:discoInfo withDelegate:self andMethod:@selector(handleServiceDiscoInfo:withIqNode:) andAdditionalArguments:nil];
        }
    }
}

//entity caps of some contact
+(void) handleEntityCapsDisco:(xmpp*) account withIqNode:(XMPPIQ*) iqNode
{
    NSMutableArray* identities = [[NSMutableArray alloc] init];
    for(MLXMLNode* identity in [iqNode find:@"{http://jabber.org/protocol/disco#info}query/identity"])
        [identities addObject:[NSString stringWithFormat:@"%@/%@//%@", [identity findFirst:@"/@category"], [identity findFirst:@"/@type"], [identity findFirst:@"/@name"]]];
    NSSet* features = [NSSet setWithArray:[iqNode find:@"{http://jabber.org/protocol/disco#info}query/feature@var"]];
    NSString* ver = [HelperTools getEntityCapsHashForIdentities:identities andFeatures:features];
    [[DataLayer sharedInstance] setCaps:features forVer:ver];
}

+(void) omemoResult:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
#ifndef DISABLE_OMEMO
    if([iqNode check:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.devicelist>"]) {
        NSArray<NSNumber*>* deviceIds =  [iqNode find:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.devicelist>/item/{eu.siacs.conversations.axolotl}list/device@id|int"];
        NSSet<NSNumber*>* deviceSet = [[NSSet<NSNumber*> alloc] initWithArray:deviceIds];
        [account.omemo processOMEMODevices:deviceSet from:iqNode.from];
    } else if([iqNode check:@"{http://jabber.org/protocol/pubsub}pubsub/items<node=eu\\.siacs\\.conversations\\.axolotl\\.bundles:[0-9]+>"]) {
        [account.omemo processOMEMOKeys:iqNode];
    }
#endif
}

+(void) iqVersionResult:(XMPPIQ*) iqNode forAccount:(xmpp*) account
{
    NSString* iqAppName = [iqNode findFirst:@"{jabber:iq:version}query/name#"];
    if(!iqAppName)
        iqAppName = @"";
    NSString* iqAppVersion = [iqNode findFirst:@"{jabber:iq:version}query/version#"];
    if(!iqAppVersion)
        iqAppVersion = @"";
    NSString* iqPlatformOS = [iqNode findFirst:@"{jabber:iq:version}query/os#"];
    if(!iqPlatformOS)
        iqPlatformOS = @"";
    
    NSArray *versionDBInfoArr = [[DataLayer sharedInstance] softwareVersionInfoForAccount:account.accountNo andContact:iqNode.fromUser];
    
    if ((versionDBInfoArr != nil) && ([versionDBInfoArr count] > 0)) {
        NSDictionary *versionInfoDBDic = versionDBInfoArr[0];
        
        if (!([[versionInfoDBDic objectForKey:@"platform_App_Name"] isEqualToString:iqAppName] &&
            [[versionInfoDBDic objectForKey:@"platform_App_Version"] isEqualToString:iqAppVersion] &&
            [[versionInfoDBDic objectForKey:@"platform_OS"] isEqualToString:iqPlatformOS]))
        {
            [[DataLayer sharedInstance] setSoftwareVersionInfoForAppName:iqAppName
                                                             appVersion:iqAppVersion
                                                             platformOS:iqPlatformOS
                                                            withAccount:account.accountNo
                                                             andContact:iqNode.fromUser];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:kMonalXmppUserSoftWareVersionRefresh
                                                                object:account
                                                              userInfo:@{@"platform_App_Name":iqAppName,
                                                                      @"platform_App_Version":iqAppVersion,
                                                                               @"platform_OS":iqPlatformOS}];
        }
    }
}

@end
