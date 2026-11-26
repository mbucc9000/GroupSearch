// GroupSearch (mbucc9000): group chats show up in the To: field suggestions of a new
// message in iOS 6 Messages. Type part of a group's name and the group is listed above the
// contact matches; tap it and everyone in the group is added as a recipient.
//
// Group names come from GroupChatNameFix's /var/mobile/gcnf_names.plist (iOS 6 has no group
// names of its own). Its keys are the members, sorted and joined with "|": phone numbers as
// their last 10 digits, emails as-is, plus one of your own addresses. A conversation matches a
// key when all of its recipients are in the key and the key has at most one extra entry (you).
//
// The suggestions table belongs to CKRecipientSelectionView. Its rows come from the
// _searchResults array; group rows are put in front of them by the data source hooks below.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <sys/stat.h>

#define GS_NAMES_PATH @"/var/mobile/gcnf_names.plist"
#define GS_LOG_PATH   @"/var/mobile/GroupSearch.log"
#define GS_MAX_ROWS   5

@interface CKRecipientSelectionView : UIView
- (id)composeRecipientView:(id)view composeRecipientForAddress:(NSString *)address;
- (BOOL)isShowingSearchField;
- (void)_showSearchField;
- (void)_hideSearchField;
- (NSString *)searchText;
- (id)delegate;
@end

@interface NSObject (GroupSearchPrivate)
+ (id)sharedConversationList;
- (NSArray *)conversations;
- (NSArray *)recipients;
- (NSString *)rawAddress;
- (NSString *)name;
- (NSString *)address;
- (void)addRecipient:(id)recipient;
- (void)clearText;
- (void)reflow;
- (void)recipientSelectionViewRecipientListChanged:(id)view;
- (void)recipientSelectionView:(id)view isShowingSearchResults:(BOOL)showing;
+ (id)recipientWithProperty:(int)property address:(NSString *)address;
@end

static const void *kMatchesKey = &kMatchesKey;
static BOOL gAdjusting;

#ifdef DEBUG
static void GSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void GSLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:GS_LOG_PATH]) {
        [fm createFileAtPath:GS_LOG_PATH contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:GS_LOG_PATH];
    if ([fh seekToEndOfFile] > 128 * 1024) {
        [fh truncateFileAtOffset:0];
    }
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
#else
#define GSLog(...) do { } while (0)
#endif

// ---------------------------------------------------------------------------------------
// Group names

static NSArray *gNamedGroups;       // NSSet of normalized members per named group
static NSArray *gGroupNames;        // the matching names
static struct timespec gNamesMTime;

// "tel:+1 (555) 010-1234" -> "5550101234"; "mailto:A@B.com" -> "a@b.com".
static NSString *GSNormalize(NSString *address) {
    NSString *a = address;
    if ([a hasPrefix:@"tel:"]) {
        a = [a substringFromIndex:4];
    } else if ([a hasPrefix:@"mailto:"]) {
        a = [a substringFromIndex:7];
    }
    if ([a rangeOfString:@"@"].location != NSNotFound) {
        return [a lowercaseString];
    }
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < a.length; i++) {
        unichar c = [a characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            [digits appendFormat:@"%C", c];
        }
    }
    if (digits.length > 10) {
        return [digits substringFromIndex:digits.length - 10];
    }
    return digits.length ? digits : [a lowercaseString];
}

// Re-reads gcnf_names.plist whenever GroupChatNameFix changes it.
static void GSLoadNames(void) {
    struct stat st;
    if (stat([GS_NAMES_PATH fileSystemRepresentation], &st) != 0) {
        gNamedGroups = @[];
        gGroupNames = @[];
        return;
    }
    if (gNamedGroups && st.st_mtimespec.tv_sec == gNamesMTime.tv_sec && st.st_mtimespec.tv_nsec == gNamesMTime.tv_nsec) {
        return;
    }
    NSDictionary *names = [NSDictionary dictionaryWithContentsOfFile:GS_NAMES_PATH];
    if (![names isKindOfClass:[NSDictionary class]]) {
        return;   // mid-write; try again next time
    }
    gNamesMTime = st.st_mtimespec;
    NSMutableArray *groups = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSString *key in names) {
        id name = names[key];
        if (![key isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]] || ![name length]) {
            continue;
        }
        NSMutableSet *members = [NSMutableSet set];
        for (NSString *part in [key componentsSeparatedByString:@"|"]) {
            if (part.length) {
                [members addObject:GSNormalize(part)];
            }
        }
        [groups addObject:members];
        [labels addObject:name];
    }
    gNamedGroups = groups;
    gGroupNames = labels;
    GSLog(@"loaded %lu group names", (unsigned long)groups.count);
}

static NSArray *GSRawAddresses(id conversation) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *recipients = [conversation respondsToSelector:@selector(recipients)] ? [conversation recipients] : nil;
    for (id r in recipients) {
        NSString *raw = [r respondsToSelector:@selector(rawAddress)] ? [r rawAddress] : nil;
        if ([raw isKindOfClass:[NSString class]] && raw.length) {
            [out addObject:raw];
        }
    }
    return out;
}

static NSString *GSNameForMembers(NSSet *members) {
    for (NSUInteger i = 0; i < gNamedGroups.count; i++) {
        NSSet *key = gNamedGroups[i];
        if ([members isSubsetOfSet:key] && key.count <= members.count + 1) {
            return gGroupNames[i];
        }
    }
    return nil;
}

// Folded for matching: case, accents and curly quotes don't matter.
static NSString *GSFold(NSString *s) {
    NSString *f = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    f = [f stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    return [f stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// The query matches when it starts the whole name or any word in it ("fam" finds "The Fam").
static BOOL GSNameMatches(NSString *name, NSString *query) {
    NSString *n = GSFold(name);
    if ([n hasPrefix:query]) {
        return YES;
    }
    NSCharacterSet *sep = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSUInteger len = n.length;
    for (NSUInteger i = 1; i < len; i++) {
        if ([sep characterIsMember:[n characterAtIndex:i - 1]] && ![sep characterIsMember:[n characterAtIndex:i]]) {
            if ([[n substringFromIndex:i] hasPrefix:query]) {
                return YES;
            }
        }
    }
    return NO;
}

// Each match: @{ @"name": NSString, @"addresses": NSArray of raw addresses }.
static NSArray *GSFindGroups(NSString *text) {
    NSString *query = GSFold(text ?: @"");
    if (!query.length) {
        return nil;
    }
    GSLoadNames();
    if (!gNamedGroups.count) {
        return nil;
    }
    Class listClass = objc_getClass("CKConversationList");
    id list = [listClass respondsToSelector:@selector(sharedConversationList)] ? [listClass sharedConversationList] : nil;
    NSArray *conversations = [list respondsToSelector:@selector(conversations)] ? [list conversations] : nil;
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableSet *seenNames = [NSMutableSet set];
    for (id conversation in conversations) {
        NSArray *addresses = GSRawAddresses(conversation);
        if (addresses.count < 2) {
            continue;
        }
        NSMutableSet *members = [NSMutableSet set];
        for (NSString *a in addresses) {
            [members addObject:GSNormalize(a)];
        }
        NSString *name = GSNameForMembers(members);
        if (!name || !GSNameMatches(name, query)) {
            continue;
        }
        // Same name twice (an old copy of the group): keep the first, the list is newest first.
        NSString *nameKey = [GSFold(name) stringByAppendingFormat:@"|%lu", (unsigned long)members.count];
        if ([seenNames containsObject:nameKey]) {
            continue;
        }
        [seenNames addObject:nameKey];
        [matches addObject:@{ @"name": name, @"addresses": addresses }];
        if (matches.count >= GS_MAX_ROWS) {
            break;
        }
    }
    return matches.count ? matches : nil;
}

// ---------------------------------------------------------------------------------------
// Selection view helpers

static id GSIvar(id obj, const char *name) {
    Ivar iv = class_getInstanceVariable([obj class], name);
    return iv ? object_getIvar(obj, iv) : nil;
}

static NSArray *GSMatches(id view) {
    return objc_getAssociatedObject(view, kMatchesKey);
}

static void GSSetMatches(id view, NSArray *matches) {
    objc_setAssociatedObject(view, kMatchesKey, matches, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL GSIsResultsTable(id view, UITableView *tableView) {
    return tableView && tableView == GSIvar(view, "_searchResultsTable");
}

static NSString *GSMemberSummary(NSArray *addresses, id view) {
    NSMutableArray *names = [NSMutableArray array];
    id toField = GSIvar(view, "_toField");
    for (NSString *a in addresses) {
        id r = [view composeRecipientView:toField composeRecipientForAddress:a];
        NSString *n = [r respondsToSelector:@selector(displayString)] ? [r performSelector:@selector(displayString)] : nil;
        if (![n isKindOfClass:[NSString class]] || !n.length) {
            n = a;
        }
        NSRange space = [n rangeOfString:@" "];
        if (space.location != NSNotFound && [n rangeOfString:@"@"].location == NSNotFound
            && [n rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
            n = [n substringToIndex:space.location];   // first names keep it short
        }
        [names addObject:n];
    }
    return [names componentsJoinedByString:@", "];
}

static void GSAddGroup(CKRecipientSelectionView *view, NSDictionary *match) {
    id toField = GSIvar(view, "_toField");
    if (!toField) {
        return;
    }
    NSMutableSet *present = [NSMutableSet set];
    NSArray *existing = [toField respondsToSelector:@selector(recipients)] ? [toField recipients] : nil;
    for (id r in existing) {
        NSString *a = [r respondsToSelector:@selector(address)] ? [r address] : nil;
        if ([a isKindOfClass:[NSString class]]) {
            [present addObject:GSNormalize(a)];
        }
    }
    // Same order as stock -tableView:didSelectRowAtIndexPath: (hide, add, tell the delegate,
    // clear, reflow, report search state), with every member added before the delegate hears.
    GSSetMatches(view, nil);
    [view _hideSearchField];
    NSUInteger added = 0;
    for (NSString *address in match[@"addresses"]) {
        if ([present containsObject:GSNormalize(address)]) {
            continue;
        }
        id recipient = [view composeRecipientView:toField composeRecipientForAddress:address];
        if (!recipient) {
            Class rc = objc_getClass("MFComposeRecipient");
            BOOL email = [address rangeOfString:@"@"].location != NSNotFound;
            recipient = [rc recipientWithProperty:(email ? 4 : 3) address:address];   // kABPersonEmail/PhoneProperty
        }
        if (recipient) {
            [toField addRecipient:recipient];
            [present addObject:GSNormalize(address)];
            added++;
        }
    }
    GSLog(@"picked a group: %lu members, %lu added", (unsigned long)[match[@"addresses"] count], (unsigned long)added);
    id delegate = [view delegate];
    if ([delegate respondsToSelector:@selector(recipientSelectionViewRecipientListChanged:)]) {
        [delegate recipientSelectionViewRecipientListChanged:view];
    }
    if ([toField respondsToSelector:@selector(clearText)]) {
        [toField clearText];
    }
    if ([toField respondsToSelector:@selector(reflow)]) {
        [toField reflow];
    }
    if ([delegate respondsToSelector:@selector(recipientSelectionView:isShowingSearchResults:)]) {
        [delegate recipientSelectionView:view isShowingSearchResults:[view isShowingSearchField]];
    }
}

// ---------------------------------------------------------------------------------------

%hook CKRecipientSelectionView

- (void)_searchWithText:(NSString *)text
{
    NSArray *matches = GSFindGroups(text);
    GSSetMatches(self, matches);
    %orig;
    if (matches.count) {
        GSLog(@"query length %lu: %lu group matches", (unsigned long)text.length, (unsigned long)matches.count);
        if (![self isShowingSearchField]) {
            gAdjusting = YES;
            [self _showSearchField];
            gAdjusting = NO;
        }
        [(UITableView *)GSIvar(self, "_searchResultsTable") reloadData];
    }
}

- (void)setSearchText:(NSString *)text
{
    if (!text.length) {
        GSSetMatches(self, nil);
    }
    %orig;
}

- (void)reset
{
    GSSetMatches(self, nil);
    %orig;
}

// Stock hides the suggestions when no contact matches; keep them up for a group match.
- (void)_hideSearchField
{
    if (!gAdjusting && GSMatches(self).count && [self searchText].length) {
        return;
    }
    %orig;
}

- (void)_updateShowingSearch
{
    %orig;
    if (GSMatches(self).count && [self searchText].length && ![self isShowingSearchField]) {
        gAdjusting = YES;
        [self _showSearchField];
        gAdjusting = NO;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger n = %orig;
    if (section == 0 && GSIsResultsTable(self, tableView)) {
        n += GSMatches(self).count;
    }
    return n;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *matches = GSIsResultsTable(self, tableView) ? GSMatches(self) : nil;
    if (!matches.count || indexPath.section != 0) {
        return %orig;
    }
    if ((NSUInteger)indexPath.row >= matches.count) {
        return %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - matches.count inSection:indexPath.section]);
    }
    static NSString *ident = @"GroupSearchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ident];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }
    NSDictionary *match = matches[indexPath.row];
    NSArray *addresses = match[@"addresses"];
    cell.textLabel.text = match[@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Group: %@", GSMemberSummary(addresses, self)];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray *matches = GSIsResultsTable(self, tableView) ? GSMatches(self) : nil;
    if (!matches.count || indexPath.section != 0) {
        %orig;
        return;
    }
    if ((NSUInteger)indexPath.row >= matches.count) {
        %orig(tableView, [NSIndexPath indexPathForRow:indexPath.row - matches.count inSection:indexPath.section]);
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    GSAddGroup(self, matches[indexPath.row]);
}

%end
