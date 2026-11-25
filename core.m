// rayfast core: config, global hotkeys, app launching, and the respawn trick. The UI lives in ui.m.
#include "rf.h"
#include <mach/mach_time.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

#pragma mark - paths

NSString *cfgDir(void) { return getenv("RF_CONFIG_DIR") ? @(getenv("RF_CONFIG_DIR")) : [NSHomeDirectory() stringByAppendingPathComponent:@".config/rayfast"]; }
NSString *cfgPath(void) { return [cfgDir() stringByAppendingPathComponent:@"config"]; }
NSString *trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; }
time_t mtimeOf(NSString *p) { struct stat st; return stat(p.fileSystemRepresentation, &st) ? 0 : st.st_mtime; }

#pragma mark - hotkeys

typedef struct { const char *n; UInt16 k; } KeyName;
static const KeyName KEYS[] = {
    {"a", 0}, {"s", 1}, {"d", 2}, {"f", 3}, {"h", 4}, {"g", 5}, {"z", 6}, {"x", 7}, {"c", 8}, {"v", 9}, {"b", 11}, {"q", 12},
    {"w", 13}, {"e", 14}, {"r", 15}, {"y", 16}, {"t", 17}, {"1", 18}, {"2", 19}, {"3", 20}, {"4", 21}, {"6", 22}, {"5", 23},
    {"=", 24}, {"9", 25}, {"7", 26}, {"-", 27}, {"8", 28}, {"0", 29}, {"]", 30}, {"o", 31}, {"u", 32}, {"[", 33}, {"i", 34},
    {"p", 35}, {"return", 36}, {"l", 37}, {"j", 38}, {"'", 39}, {"k", 40}, {";", 41}, {"\\", 42}, {",", 43}, {"/", 44},
    {"n", 45}, {"m", 46}, {".", 47}, {"tab", 48}, {"space", 49}, {"`", 50}, {"delete", 51}, {"escape", 53}, {"enter", 76},
    {"f1", 122}, {"f2", 120}, {"f3", 99}, {"f4", 118}, {"f5", 96}, {"f6", 97}, {"f7", 98}, {"f8", 100}, {"f9", 101},
    {"f10", 109}, {"f11", 103}, {"f12", 111}, {"f13", 105}, {"f14", 107}, {"f15", 113}, {"f16", 106}, {"f17", 64}, {"f18", 79},
    {"f19", 80}, {"home", 115}, {"end", 119}, {"pageup", 116}, {"pagedown", 121}, {"left", 123}, {"right", 124}, {"down", 125}, {"up", 126}};

BOOL isFKey(UInt16 k) { for (size_t i = 0; i < sizeof KEYS / sizeof *KEYS; i++) if (KEYS[i].k == k) return KEYS[i].n[0] == 'f' && KEYS[i].n[1]; return NO; }
BOOL parseCombo(NSString *s, UInt32 *key, UInt32 *mods) {
    *mods = 0; *key = UINT32_MAX;
    for (NSString *raw in [s.lowercaseString componentsSeparatedByString:@"+"]) {
        NSString *p = trim(raw);
        if ([p isEqual:@"cmd"] || [p isEqual:@"command"] || [p isEqual:@"⌘"]) *mods |= cmdKey;
        else if ([p isEqual:@"opt"] || [p isEqual:@"option"] || [p isEqual:@"alt"] || [p isEqual:@"⌥"]) *mods |= optionKey;
        else if ([p isEqual:@"ctrl"] || [p isEqual:@"control"] || [p isEqual:@"⌃"]) *mods |= controlKey;
        else if ([p isEqual:@"shift"] || [p isEqual:@"⇧"]) *mods |= shiftKey;
        else if ([p isEqual:@"hyper"]) *mods |= cmdKey | optionKey | controlKey | shiftKey;
        else {
            for (size_t i = 0; i < sizeof KEYS / sizeof *KEYS; i++) if (!strcmp(KEYS[i].n, p.UTF8String)) *key = KEYS[i].k;
            if (*key == UINT32_MAX) return NO;
        }
    }
    return *key != UINT32_MAX;
}
NSString *comboString(UInt32 key, UInt32 mods, BOOL pretty) {
    NSMutableString *s = [NSMutableString string];
    const char *kn = "?";
    for (size_t i = 0; i < sizeof KEYS / sizeof *KEYS; i++) if (KEYS[i].k == key) { kn = KEYS[i].n; break; }
    if (pretty) {
        if (mods & controlKey) [s appendString:@"⌃"];
        if (mods & optionKey) [s appendString:@"⌥"];
        if (mods & shiftKey) [s appendString:@"⇧"];
        if (mods & cmdKey) [s appendString:@"⌘"];
        NSString *k = @(kn);
        NSDictionary *sym = @{@"space": @"Space", @"return": @"↩", @"left": @"←", @"right": @"→", @"up": @"↑", @"down": @"↓", @"tab": @"⇥", @"delete": @"⌫"};
        [s appendString:sym[k] ?: k.uppercaseString];
    } else {
        if (mods & controlKey) [s appendString:@"ctrl+"];
        if (mods & optionKey) [s appendString:@"opt+"];
        if (mods & shiftKey) [s appendString:@"shift+"];
        if (mods & cmdKey) [s appendString:@"cmd+"];
        [s appendString:@(kn)];
    }
    return s;
}

@implementation Binding
@end

#pragma mark - config + registration

NSMutableArray<Binding *> *gBinds;
Binding *gToggle;
NSString *gCodexPath, *gCodexModel, *gCodexSandbox;   // optional config overrides; nil = defaults in codex.m
static UInt32 gNextHid;
static time_t gCfgMtime;

void rfUnregister(Binding *b) { if (b->ref) { UnregisterEventHotKey(b->ref); b->ref = NULL; } }
void rfRegister(Binding *b) {
    rfUnregister(b);
    // test instances must not grab the user's real hotkeys (RF_TOGGLE gives them a private launcher combo)
    if (getenv("RF_NOHOTKEY") && !(b == gToggle && getenv("RF_TOGGLE"))) return;
    b->hid = ++gNextHid;
    OSStatus st = RegisterEventHotKey(b->key, b->mods, (EventHotKeyID){'rfst', b->hid}, GetApplicationEventTarget(), 0, &b->ref);
    if (st) NSLog(@"rayfast: could not register %@ (%d)", comboString(b->key, b->mods, NO), (int)st);
}
void rfSaveConfig(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:cfgDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableString *s = [NSMutableString stringWithString:
        @"# rayfast config. Reloaded automatically when the launcher opens.\n"
        @"# Modifiers: cmd opt ctrl shift hyper.  Keys: a-z 0-9 f1-f19 space return tab left right up down ...\n"
        @"# Bind apps with:  ctrl+opt+s = /Applications/Safari.app   (or press ⌘K on an app in the launcher)\n"
        @"# Codex (⌘↩ on 2+ words):  codex = /path/to/codex   codex_model = gpt-6-luna   codex_sandbox = read-only\n\n"];
    [s appendFormat:@"toggle = %@\n\n", comboString(gToggle->key, gToggle->mods, NO)];
    for (Binding *b in gBinds) [s appendFormat:@"%@ = %@\n", comboString(b->key, b->mods, NO), b->path];
    if (gCodexPath || gCodexModel || gCodexSandbox) [s appendString:@"\n"];
    if (gCodexPath) [s appendFormat:@"codex = %@\n", gCodexPath];
    if (gCodexModel) [s appendFormat:@"codex_model = %@\n", gCodexModel];
    if (gCodexSandbox) [s appendFormat:@"codex_sandbox = %@\n", gCodexSandbox];
    [s writeToFile:cfgPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gCfgMtime = mtimeOf(cfgPath());
}
static void loadConfig(void) {
    for (Binding *b in gBinds) rfUnregister(b);
    if (gToggle) rfUnregister(gToggle);
    gBinds = [NSMutableArray array];
    gCodexPath = gCodexModel = gCodexSandbox = nil;
    gToggle = [Binding new];
    parseCombo(@"cmd+space", &gToggle->key, &gToggle->mods);
    NSString *txt = [NSString stringWithContentsOfFile:cfgPath() encoding:NSUTF8StringEncoding error:nil];
    if (!txt) { rfSaveConfig(); txt = @""; }
    for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
        NSString *l = trim(line);
        if (!l.length || [l hasPrefix:@"#"]) continue;
        NSRange r = [l rangeOfString:@" = "];
        if (r.location == NSNotFound) continue;
        NSString *k = trim([l substringToIndex:r.location]), *v = trim([l substringFromIndex:NSMaxRange(r)]);
        if ([k isEqual:@"toggle"]) { parseCombo(v, &gToggle->key, &gToggle->mods); continue; }
        if ([k isEqual:@"mode"]) continue;   // older configs: there is only one mode now
        if ([k isEqual:@"codex"]) { gCodexPath = [v stringByExpandingTildeInPath]; continue; }
        if ([k isEqual:@"codex_model"]) { gCodexModel = v; continue; }
        if ([k isEqual:@"codex_sandbox"]) { gCodexSandbox = v; continue; }
        Binding *b = [Binding new];
        if (!parseCombo(k, &b->key, &b->mods)) { NSLog(@"rayfast: bad hotkey '%@'", k); continue; }
        b->path = [v stringByExpandingTildeInPath];
        [gBinds addObject:b];
    }
    if (getenv("RF_TOGGLE")) parseCombo(@(getenv("RF_TOGGLE")), &gToggle->key, &gToggle->mods);
    rfRegister(gToggle);
    for (Binding *b in gBinds) rfRegister(b);
    gCfgMtime = mtimeOf(cfgPath());
}
void rfReloadConfigIfChanged(void) { if (mtimeOf(cfgPath()) != gCfgMtime) loadConfig(); }

#pragma mark - apps

// Opens (or, from a hotkey, toggles) an app using LaunchServices + the Process Manager.
void rfOpenApp(NSString *path, BOOL fromHotkey) {
    ProcessSerialNumber psn; FSRef ref;
    if (fromHotkey && GetFrontProcess(&psn) == noErr && GetProcessBundleLocation(&psn, &ref) == noErr) {
        CFURLRef u = CFURLCreateFromFSRef(NULL, &ref);
        BOOL same = u && [[(__bridge NSURL *)u path] isEqual:path];
        if (u) CFRelease(u);
        if (same) { ShowHideProcess(&psn, false); return; }
    }
    LSOpenCFURLRef((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
}

#pragma mark - respawn + entry

// Using the window fragments AppKit's heap (~10 MB that never comes back). A few seconds after the launcher
// hides, the UI calls this: re-exec in place (same pid), hotkeys re-registered, heap back to its cold size.
void rfRespawn(void) {
    char exe[PATH_MAX]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) return;
    char *args[] = {exe, NULL};
    execv(exe, args);
}

uint64_t gHotkeyAt;   // mach_absolute_time of the last launcher hotkey (RF_DEBUG latency logging)

static OSStatus hotkeyHandler(EventHandlerCallRef c, EventRef e, void *u) {
    EventHotKeyID hid;
    GetEventParameter(e, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof hid, NULL, &hid);
    if (hid.id == gToggle->hid) { gHotkeyAt = mach_absolute_time(); uiToggle(); return noErr; }
    for (Binding *b in gBinds) if (b->hid == hid.id) { rfOpenApp(b->path, YES); break; }
    return noErr;
}

int main(int argc, const char **argv) {
    // libmalloc's space-efficient mode trims ~1 MB of allocator slack. It's read at process start,
    // so set it and re-exec once (respawns inherit it).
    if (!getenv("MallocSpaceEfficient") && argc == 1) { setenv("MallocSpaceEfficient", "1", 1); rfRespawn(); }
    @autoreleasepool {
        if (argc > 2 && !strcmp(argv[1], "--eval")) return uiEval(argc, argv);   // rayfast --eval "5 km to mi"
        sigset_t none; sigemptyset(&none); sigprocmask(SIG_SETMASK, &none, NULL);   // the signal mask survives execv()
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(&hotkeyHandler, 1, &spec, NULL, NULL);
        loadConfig();
        // `kill -USR1 <pid>` toggles the launcher; with RF_SNAP set, `kill -USR2` renders a debug snapshot.
        static dispatch_source_t s1, s2;
        signal(SIGUSR1, SIG_IGN);
        s1 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(s1, ^{ uiToggle(); });
        dispatch_resume(s1);
        if (getenv("RF_SNAP")) {
            signal(SIGUSR2, SIG_IGN);
            s2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(s2, ^{ uiSnapshot(); });
            dispatch_resume(s2);
        }
        uiRun();   // never returns
    }
}
