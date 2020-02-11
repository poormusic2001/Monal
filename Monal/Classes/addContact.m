//
//  buddyDetails.m
//  SworIM
//
//  Created by Anurodh Pokharel on 6/21/09.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "addContact.h"
#import "MLConstants.h"
#import "MLXMPPManager.h"
#import "MLButtonCell.h"
#import "MLTextInputCell.h"
#import "MLAccountPickerViewController.h"

@implementation addContact


-(void) closeView
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

-(IBAction) addPress:(id)sender
{
    if([[MLXMPPManager sharedInstance].connectedXMPP count]==0)
    {
        UIAlertController *messageAlert =[UIAlertController alertControllerWithTitle:@"No connected accounts" message:@"Please make sure at least one account has connected before trying to add a contact." preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *closeAction =[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            
        }];
        [messageAlert addAction:closeAction];
        
        [self presentViewController:messageAlert animated:YES completion:nil];
    }
    else  {
        
        if(self.contactName.text.length>0)
        {
            NSDictionary* contact =@{@"row":[NSNumber numberWithInteger:_selectedRow],@"buddy_name":self.contactName.text};
            [[MLXMPPManager sharedInstance] addContact:contact];
            
            NSDictionary* datarow= [[MLXMPPManager sharedInstance].connectedXMPP objectAtIndex:_selectedRow];
            xmpp* account= (xmpp*)[datarow objectForKey:@"xmppAccount"];
            
            MLContact *contactObj = [[MLContact alloc] init];
            contactObj.contactJid=self.contactName.text;
            contactObj.accountId= account.accountNo;
            
            UIAlertController *messageAlert =[UIAlertController alertControllerWithTitle:@"Permission Requested" message:@"The new contact will be added to your contacts list when the person you've added has approved your request." preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *closeAction =[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                if(self.completion) self.completion(contactObj);
                [self dismissViewControllerAnimated:YES completion:nil];
            }];
            [messageAlert addAction:closeAction];
            
            [self presentViewController:messageAlert animated:YES completion:nil];
            
        }
        else
        {
            UIAlertController *messageAlert =[UIAlertController alertControllerWithTitle:@"Error" message:@"Name can't be empty" preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *closeAction =[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                
            }];
            [messageAlert addAction:closeAction];
            
            [self presentViewController:messageAlert animated:YES completion:nil];
            
        }
        
    }
}

#pragma mark - textfield delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    
	return YES;
}


- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    
    _currentTextField=textField;
    return YES;
}


#pragma mark View life cycle

-(void) viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.title=@"Add Contact";
    _closeButton =[[UIBarButtonItem alloc] initWithTitle:@"Close" style:UIBarButtonItemStylePlain target:self action:@selector(closeView)];
    self.navigationItem.rightBarButtonItem=_closeButton;
        
    [self.tableView registerNib:[UINib nibWithNibName:@"MLTextInputCell"
                                               bundle:[NSBundle mainBundle]]
         forCellReuseIdentifier:@"TextCell"];
    
    
}

-(void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if([[MLXMPPManager sharedInstance].connectedXMPP count]==1)
    {
        [[MLXMPPManager sharedInstance] getServiceDetailsForAccount:0];
        _selectedRow=0;
    }
}

#pragma mark tableview datasource delegate

-(NSInteger) numberOfSectionsInTableView:(UITableView *)tableView
{
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if(section==0)
    {
        return @"Contacts are usually in the format: username@domain.something";
    }
    else return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger toreturn =0;
    switch (section) {
        case 0:
            toreturn =2;
            break;
        case 1:
            toreturn=1;
            break;
            
        default:
            break;
    }
    
    return toreturn;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell ;
  
    switch (indexPath.section) {
        case 0: {
            if(indexPath.row ==0){
                UITableViewCell *accountCell =[tableView dequeueReusableCellWithIdentifier:@"AccountCell"];
                if([[MLXMPPManager sharedInstance].connectedXMPP count]==1) {
                    accountCell.textLabel.text=[NSString stringWithFormat:@"Using Account: %@", [[MLXMPPManager sharedInstance] getAccountNameForConnectedRow:0]];
                }
                cell=accountCell;
            }
            else   if(indexPath.row ==1){
                MLTextInputCell *textCell =[tableView dequeueReusableCellWithIdentifier:@"TextCell"];
                self.contactName =textCell.textInput;
                self.contactName.placeholder = @"Contact Name";
                self.contactName.delegate=self;
                cell= textCell;
            }
            
            break;
        }
        case 1: {
            cell =[tableView dequeueReusableCellWithIdentifier:@"addButton"];
            break;
        }
        default:
            break;
    }
  return cell;
}

#pragma mark tableview delegate
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case 0: {
            if(indexPath.row ==0){
                [self performSegueWithIdentifier:@"showAccountPicker" sender:self];
            }
        }
    }
}

- (void) prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if([segue.identifier isEqualToString:@"showAccountPicker"])
    {
        MLAccountPickerViewController *accountPicker = (MLAccountPickerViewController *) segue.destinationViewController;
        
    }
    
}

@end
