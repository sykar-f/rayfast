// rayfast Codex: the conversation behind ⌘↩. Like the currency fetch (curl), all the work happens out of process:
// each turn is one `codex exec --json` (later turns `codex exec resume <thread>`), whose JSONL events become a
// status line and an answer. Between turns nothing runs; the conversation is the thread id plus what ui.m shows.
#import <Cocoa/Cocoa.h>
#include "rf.h"

NSString *cxStatus, *cxAnswer, *cxError;
void (^cxChanged)(void);
static NSString *gThread;
static NSTask *gTask;
static int gGen;            // bumped by cxReset, so events from a killed turn are dropped
static double gStarted;

BOOL cxBusy(void) { return gTask != nil; }
double cxStartedAt(void) { return gStarted; }
NSString *cxModel(void) { return gCodexModel ?: @"gpt-6-luna"; }
static void changed(void) { if (cxChanged) cxChanged(); }

// A LaunchAgent gets a bare PATH, so look where codex usually lives instead of asking a (slow) login shell.
static NSArray<NSString *> *binDirs(void) {
    return @[[NSString stringWithFormat:@"/etc/profiles/per-user/%@/bin", NSUserName()], @"/run/current-system/sw/bin",
             @"/opt/homebrew/bin", @"/usr/local/bin", [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"]];
}
static NSString *codexPath(void) {
    if (gCodexPath) return gCodexPath;
    NSArray *path = [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"] ?: @[];
    for (NSString *d in [path arrayByAddingObjectsFromArray:binDirs()]) {
        NSString *p = [d stringByAppendingPathComponent:@"codex"];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static NSString *statusFor(NSDictionary *item) {
    NSString *t = str(item[@"type"]);
    if ([t isEqual:@"command_execution"]) {
        NSString *c = str(item[@"command"]) ?: @"";
        NSRange r = [c rangeOfString:@" -lc '"];   // codex wraps every command as /bin/zsh -lc '…'
        if (r.location != NSNotFound && [c hasSuffix:@"'"]) c = [c substringWithRange:NSMakeRange(NSMaxRange(r), c.length - NSMaxRange(r) - 1)];
        return [@"Running " stringByAppendingString:[c stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    }
    if ([t isEqual:@"web_search"]) return @"Searching the web…";
    if ([t isEqual:@"file_change"]) return @"Editing files…";
    if ([t isEqual:@"mcp_tool_call"]) return @"Using a tool…";
    if ([t isEqual:@"reasoning"]) return @"Thinking…";
    return nil;
}
static void handle(NSDictionary *ev) {
    NSString *type = str(ev[@"type"]);
    NSDictionary *item = [ev[@"item"] isKindOfClass:NSDictionary.class] ? ev[@"item"] : nil;
    if ([type isEqual:@"thread.started"]) gThread = str(ev[@"thread_id"]) ?: gThread;
    else if ([type isEqual:@"turn.started"]) cxStatus = @"Thinking…";
    else if ([type isEqual:@"item.started"]) cxStatus = statusFor(item) ?: cxStatus;
    else if ([type isEqual:@"item.completed"]) {
        if ([item[@"type"] isEqual:@"agent_message"]) cxAnswer = str(item[@"text"]) ?: cxAnswer;   // the last one is the answer
        cxStatus = @"Thinking…";
    }
    else if ([type isEqual:@"turn.failed"]) cxError = [ev[@"error"] isKindOfClass:NSDictionary.class] ? str(ev[@"error"][@"message"]) : @"Turn failed";
    else if ([type isEqual:@"error"]) cxError = str(ev[@"message"]);
    else if ([type isEqual:@"turn.completed"]) cxError = nil;   // errors before this were retries that recovered
    else return;
    changed();
}
// codex prints fatal errors (no login, unknown thread…) on stderr; the last real line says what went wrong.
static NSString *lastLine(NSString *path) {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    for (NSString *l in [s componentsSeparatedByString:@"\n"].reverseObjectEnumerator) {
        NSString *t = trim(l);
        if (!t.length || [t hasPrefix:@"Reading additional input"]) continue;
        return [t hasPrefix:@"Error: "] ? [t substringFromIndex:7] : t;
    }
    return nil;
}

void cxSend(NSString *prompt) {
    if (gTask) return;
    cxStatus = @"Starting Codex…"; cxAnswer = nil; cxError = nil;
    NSString *exe = codexPath();
    if (!exe) { cxStatus = nil; cxError = @"Codex CLI not found. Add its path to the config:  codex = /path/to/codex"; changed(); return; }
    // Its own working dir in $TMPDIR: with the default workspace-write sandbox, codex can write there and in /tmp only.
    NSString *wd = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rayfast-codex"], *errPath = [wd stringByAppendingPathComponent:@"stderr.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:wd withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createFileAtPath:errPath contents:nil attributes:nil];
    NSMutableArray *args = [NSMutableArray arrayWithObject:@"exec"];
    if (gThread) [args addObject:@"resume"];
    [args addObjectsFromArray:@[@"--json", @"--skip-git-repo-check", @"-m", cxModel(),
                                @"-c", [NSString stringWithFormat:@"sandbox_mode=\"%@\"", gCodexSandbox ?: @"workspace-write"], @"--"]];
    if (gThread) [args addObject:gThread];
    [args addObject:prompt];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"PATH"] = [[binDirs() arrayByAddingObject:env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin"] componentsJoinedByString:@":"];
    [env removeObjectForKey:@"MallocSpaceEfficient"];   // rayfast's own allocator setting, not codex's
    NSTask *t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:exe];
    t.arguments = args;
    t.currentDirectoryURL = [NSURL fileURLWithPath:wd];
    t.environment = env;
    t.standardInput = NSFileHandle.fileHandleWithNullDevice;
    t.standardError = [NSFileHandle fileHandleForWritingAtPath:errPath];   // a file, so a chatty stderr can never block codex
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    NSError *e;
    if (![t launchAndReturnError:&e]) { cxStatus = nil; cxError = [@"Could not start Codex: " stringByAppendingString:e.localizedDescription]; changed(); return; }
    gTask = t; gStarted = CFAbsoluteTimeGetCurrent();
    int gen = ++gGen;
    changed();
    NSFileHandle *h = out.fileHandleForReading;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *buf = [NSMutableData data];
        NSData *d;
        while ((d = h.availableData).length) {   // one JSON event per line
            [buf appendData:d];
            const char *b = buf.bytes; NSUInteger start = 0;
            for (NSUInteger i = 0; i < buf.length; i++) {
                if (b[i] != '\n') continue;
                id ev = [NSJSONSerialization JSONObjectWithData:[buf subdataWithRange:NSMakeRange(start, i - start)] options:0 error:nil];
                if ([ev isKindOfClass:NSDictionary.class]) dispatch_async(dispatch_get_main_queue(), ^{ if (gen == gGen) handle(ev); });
                start = i + 1;
            }
            [buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
        }
        [t waitUntilExit];
        int st = t.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != gGen) return;
            gTask = nil; cxStatus = nil;
            if (st && !cxError) cxError = lastLine(errPath) ?: [NSString stringWithFormat:@"Codex exited with status %d", st];
            changed();
        });
    });
}

void cxReset(void) {
    gGen++;
    if (gTask.running) [gTask terminate];
    gTask = nil; gThread = nil;
    cxStatus = cxAnswer = cxError = nil;
}

#pragma mark - markdown

// Inline syntax comes from Foundation's own parser (bold, italic, `code`, links, strikethrough); its presentation
// intents are mapped to fonts here. Block syntax is handled line by line: headings become bold lines, bullets get
// a •, and fenced code becomes its own block (CX_CODE) that the UI draws monospaced on a tinted card.
static NSAttributedString *prose(NSString *md) {
    NSAttributedStringMarkdownParsingOptions *o = [NSAttributedStringMarkdownParsingOptions new];
    o.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnlyPreservingWhitespace;
    o.failurePolicy = NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible;
    NSAttributedString *parsed = [[NSAttributedString alloc] initWithMarkdownString:md options:o baseURL:nil error:nil];
    NSMutableAttributedString *a = parsed ? [parsed mutableCopy] : [[NSMutableAttributedString alloc] initWithString:md];
    static NSMutableParagraphStyle *ps;
    if (!ps) { ps = [NSMutableParagraphStyle new]; ps.lineSpacing = 2; ps.paragraphSpacing = 8; }
    NSRange all = NSMakeRange(0, a.length);
    [a addAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:14], NSForegroundColorAttributeName: NSColor.labelColor,
                       NSParagraphStyleAttributeName: ps} range:all];
    [a enumerateAttribute:NSInlinePresentationIntentAttributeName inRange:all options:0 usingBlock:^(NSNumber *v, NSRange r, BOOL *stop) {
        NSUInteger i = v.unsignedIntegerValue;
        if (!i) return;
        NSFontWeight w = i & NSInlinePresentationIntentStronglyEmphasized ? NSFontWeightSemibold : NSFontWeightRegular;
        NSFont *f = i & NSInlinePresentationIntentCode ? [NSFont monospacedSystemFontOfSize:13 weight:w] : [NSFont systemFontOfSize:14 weight:w];
        if (i & NSInlinePresentationIntentEmphasized) f = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSItalicFontMask];
        [a addAttribute:NSFontAttributeName value:f range:r];
        if (i & NSInlinePresentationIntentCode) [a addAttribute:NSBackgroundColorAttributeName value:[NSColor.labelColor colorWithAlphaComponent:0.08] range:r];
        if (i & NSInlinePresentationIntentStrikethrough) [a addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:r];
    }];
    [a enumerateAttribute:NSLinkAttributeName inRange:all options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (!v) return;   // links aren't clickable here: keep the text, underlined
        [a removeAttribute:NSLinkAttributeName range:r];
        [a addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:r];
    }];
    return a;
}
static NSAttributedString *codeBlock(NSString *s) {
    static NSMutableParagraphStyle *ps;
    if (!ps) { ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByCharWrapping; ps.lineSpacing = 1; }
    return [[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.labelColor, NSParagraphStyleAttributeName: ps, CX_CODE: @YES}];
}
// Tables become a monospaced block with padded columns (inline markers dropped): readable, and no table layout code.
static NSAttributedString *tableBlock(NSArray<NSArray<NSString *> *> *rows) {
    NSMutableArray<NSNumber *> *w = [NSMutableArray array];
    for (NSArray *r in rows) for (NSUInteger i = 0; i < r.count; i++) {
        if (i == w.count) [w addObject:@0];
        w[i] = @(MAX(w[i].unsignedIntegerValue, [r[i] length]));
    }
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger k = 0; k < rows.count; k++) {
        NSMutableArray *cells = [NSMutableArray array];
        for (NSUInteger i = 0; i < rows[k].count; i++) [cells addObject:[rows[k][i] stringByPaddingToLength:w[i].unsignedIntegerValue withString:@" " startingAtIndex:0]];
        [s appendFormat:@"%@%@", k ? @"\n" : @"", trim([cells componentsJoinedByString:@"   "])];
        if (!k && rows.count > 1) {   // rule under the header
            NSUInteger n = 0; for (NSNumber *x in w) n += x.unsignedIntegerValue; n += 3 * (w.count - 1);
            [s appendFormat:@"\n%@", [@"" stringByPaddingToLength:n withString:@"─" startingAtIndex:0]];
        }
    }
    return codeBlock(s);
}
static NSArray<NSString *> *tableCells(NSString *t) {
    NSMutableArray *c = [NSMutableArray array];
    for (NSString *x in [t componentsSeparatedByString:@"|"])
        [c addObject:trim([[x stringByReplacingOccurrencesOfString:@"**" withString:@""] stringByReplacingOccurrencesOfString:@"`" withString:@""])];
    if (c.count && ![c.firstObject length]) [c removeObjectAtIndex:0];
    if (c.count && ![c.lastObject length]) [c removeLastObject];
    return c;
}
NSArray<NSAttributedString *> *cxMarkdown(NSString *md) {
    NSMutableArray *out = [NSMutableArray array], *table = nil;
    NSMutableString *text = [NSMutableString string], *code = nil;
    void (^flush)(void) = ^{
        NSString *s = [text stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
        if (s.length) [out addObject:prose(s)];
        [text setString:@""];
    };
    NSCharacterSet *rule = [NSCharacterSet characterSetWithCharactersInString:@"|-: "];
    for (NSString *line in [md componentsSeparatedByString:@"\n"]) {
        NSString *t = trim(line), *l = line;
        if ([t hasPrefix:@"```"]) {
            if (!code) { flush(); code = [NSMutableString string]; continue; }
            if (code.length) [out addObject:codeBlock(code)];
            code = nil; continue;
        }
        if (code) { if (code.length) [code appendString:@"\n"]; [code appendString:line]; continue; }
        if (table && ![t hasPrefix:@"|"]) { if (table.count) [out addObject:tableBlock(table)]; table = nil; }
        if ([t hasPrefix:@"|"]) {
            if (!table) { flush(); table = [NSMutableArray array]; }
            if ([t stringByTrimmingCharactersInSet:rule].length) [table addObject:tableCells(t)];   // skip |---|---|
            continue;
        }
        if (!t.length) continue;   // paragraphs are spaced by the paragraph style, not by blank lines
        NSUInteger h = 0;
        while (h < t.length && h < 6 && [t characterAtIndex:h] == '#') h++;
        if (h && h < t.length && [t characterAtIndex:h] == ' ') l = [NSString stringWithFormat:@"**%@**", trim([t substringFromIndex:h])];
        else if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "] || [t hasPrefix:@"+ "])
            l = [NSString stringWithFormat:@"%@• %@", [line substringToIndex:[line rangeOfString:t].location], [t substringFromIndex:2]];
        else if ([t isEqual:@"---"] || [t isEqual:@"***"] || [t isEqual:@"___"]) l = @"";
        [text appendFormat:@"%@\n", l];
    }
    flush();
    if (table.count) [out addObject:tableBlock(table)];
    if (code.length) [out addObject:codeBlock(code)];   // unterminated fence
    return out;
}
