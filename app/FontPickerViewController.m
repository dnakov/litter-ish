//
//  FontPickerViewController.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "FontPickerViewController.h"
#import "UserPreferences.h"

@interface FontPickerViewController ()

@property NSArray<NSDictionary<NSString *, NSString *> *> *fontOptions;

@end

@implementation FontPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.fontOptions = @[
        @{
            @"name": @"Webterm Default",
            @"family": @"\"JetBrainsMono Nerd Font Mono\", \"FiraCode Nerd Font Mono\", ui-monospace, \"SFMono-Regular\", Menlo, Monaco, monospace",
            @"previewFamily": @"JetBrainsMonoNFM-Regular",
        },
        @{
            @"name": @"JetBrains Mono Nerd Font",
            @"family": @"JetBrainsMono Nerd Font Mono",
            @"previewFamily": @"JetBrainsMonoNFM-Regular",
        },
        @{
            @"name": @"FiraCode Nerd Font Mono",
            @"family": @"FiraCode Nerd Font Mono",
            @"previewFamily": @"FiraCode Nerd Font Mono",
        },
        @{
            @"name": @"System Monospace",
            @"family": @"ui-monospace",
            @"previewFamily": @"Menlo",
        },
        @{
            @"name": @"Menlo",
            @"family": @"Menlo",
            @"previewFamily": @"Menlo",
        },
        @{
            @"name": @"Monaco",
            @"family": @"Monaco",
            @"previewFamily": @"Menlo",
        },
    ];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.fontOptions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Font"];
    NSDictionary<NSString *, NSString *> *fontOption = self.fontOptions[indexPath.row];
    NSString *family = fontOption[@"family"];
    NSString *previewFamily = fontOption[@"previewFamily"];
    UIFont *font = [UIFont fontWithName:previewFamily size:18];
    if (font == nil) {
        if (@available(iOS 13.0, *)) {
            font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightRegular];
        }
    }
    if (font == nil) {
        font = [UIFont fontWithName:@"Menlo" size:18];
    }
    cell.textLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:font];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.text = fontOption[@"name"];
    if ([family isEqualToString:UserPreferences.shared.fontFamily])
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    else
        cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UserPreferences.shared.fontFamily = self.fontOptions[indexPath.row][@"family"];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
