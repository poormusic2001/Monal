//
//  MLXMPPManager.h
//  Monal
//
//  Created by Anurodh Pokharel on 6/27/13.
//
//

#import <Foundation/Foundation.h>

@class xmpp;
@class MLContact;

/**
 A singleton to control all of the active XMPP connections
 */
@interface MLXMPPManager : NSObject
{
	dispatch_source_t _pinger;
}

+(MLXMPPManager*) sharedInstance;

-(BOOL) allAccountsIdle;

#pragma  mark connectivity
/**
 Checks if there are any enabled acconts and connects them if necessary.  
 */
-(void) connectIfNecessary;

/**
 logout all accounts
 */
-(void) logoutAll;

-(void) disconnectAll;

/**
 disconnects the specified account
 */
-(void) disconnectAccount:(NSString*) accountNo;

/**
 connects the specified account
 */
-(void) connectAccount:(NSString*) accountNo;

#pragma mark XMPP commands
/**
 Remove a contact from an account
 */
-(void) removeContact:(MLContact*) contact;

/**
 Add a contact from an account
 */
-(void) addContact:(MLContact*) contact;

/**
 Block  a jid
 */
-(void) blocked:(BOOL) isBlockd Jid:(MLContact *) contact;

/**
 Returns the user set name of the conencted account
 */
-(NSString*) getAccountNameForConnectedRow:(NSInteger) row;

/*
 gets the connected account apecified by id. return nil otherwise
 */
-(xmpp*) getConnectedAccountForID:(NSString*) accountNo;

/**
 Returns YES if account is connected
 */
-(BOOL) isAccountForIdConnected:(NSString*) accountNo;

/**
 When the account estblihsed its current connection. 
 */
-(NSDate *) connectedTimeFor:(NSString*) accountNo;

/**
 update the password in the keychan and update memory cache
 */
-(void) updatePassword:(NSString*) password forAccount:(NSString*) accountNo;


#pragma mark MUC commands

/**
 Joins the selected Room on the conference server
 */
-(void) joinRoom:(NSString*) roomName withNick:(NSString*) nick andPassword:(NSString*) password forAccountRow:(NSInteger) row;

-(void) joinRoom:(NSString*) roomName withNick:(NSString*) nick andPassword:(NSString*) password forAccounId:(NSString*) accountId;
/**
 leaves a specified MUC room. 
 @param roomName room
 @param accountId the accountid number from the database
 */
-(void) leaveRoom:(NSString*) roomName withNick:(NSString*) nick forAccountId:(NSString*) accountId;

#pragma mark Jingle VOIP

/**
 Call a contact from an account
 */
-(void) callContact:(MLContact*) contact;

/**
 hangup on a contact from an account
 */
-(void) hangupContact:(MLContact*) contact;


-(void) approveContact:(MLContact*) contact;

-(void) rejectContact:(MLContact*) contact;

/**
 respond to call with either accept or not. Passes back the notifiaction dictionary
 */
-(void) handleCall:(NSDictionary*) userDic withResponse:(BOOL) accept; 

/**
Sends a message to a specified contact in account. Calls completion handler on success or failure.
 */
-(void) sendMessageAndAddToHistory:(NSString*) message toContact:(NSString*) recipient fromAccount:(NSString*) accountID isEncrypted:(BOOL) encrypted isMUC:(BOOL) isMUC isUpload:(BOOL) isUpload withCompletionHandler:(void (^)(BOOL success, NSString *messageId)) completion;
-(void)sendMessage:(NSString*) message toContact:(NSString*)contact fromAccount:(NSString*) accountNo isEncrypted:(BOOL) encrypted isMUC:(BOOL) isMUC  isUpload:(BOOL) isUpload messageId:(NSString *) messageId
withCompletionHandler:(void (^)(BOOL success, NSString *messageId)) completion;
-(void) sendChatState:(BOOL) isTyping fromAccount:(NSString*) accountNo toJid:(NSString*) jid;

#pragma mark XMPP settings

@property (nonatomic, strong, readonly) NSMutableArray* connectedXMPP;
@property (nonatomic, readonly) BOOL hasConnectivity;

@property (nonatomic, assign) BOOL hasAPNSToken;
@property (nonatomic, strong) NSString* pushToken;

@property (nonatomic, readonly) BOOL isBackgrounded;

/**
 updates delivery status after message has been sent
 */
-(void) handleSentMessage:(NSNotification*) notification;

/**
 updtes client state on server as inactive
 */
-(void) nowBackgrounded;

/**
 sets client state on server as active
 */
-(void) nowForegrounded;

-(void) pingAllAccounts;

/**
 fetch entity software version
 */
-(void) getEntitySoftWareVersionForContact:(MLContact*) contact andResource:(NSString*) resource;
/**
 Iterates through set and compares with connected accounts. Removes them. useful for active chat. 
 */
-(void) cleanArrayOfConnectedAccounts:(NSMutableArray*) dirtySet;

-(void) setPushToken:(NSString*) token;

@end
