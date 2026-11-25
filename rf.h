// rf.h — interface between core.m (config, hotkeys, app launching, respawn), ui.m (window, search, conversions)
// and codex.m (the Codex conversation).
#import <Foundation/Foundation.h>
#include <Carbon/Carbon.h>

@interface Binding : NSObject { @public UInt32 key, mods, hid; NSString *path; EventHotKeyRef ref; }
@end

// ---- core.m
extern NSMutableArray<Binding *> *gBinds;
extern Binding *gToggle;
extern uint64_t gHotkeyAt;
extern NSString *gCodexPath, *gCodexModel, *gCodexSandbox;   // config keys codex, codex_model, codex_sandbox (nil = default)
NSString *cfgDir(void);
NSString *cfgPath(void);
NSString *trim(NSString *s);
time_t mtimeOf(NSString *p);
BOOL isFKey(UInt16 k);
BOOL parseCombo(NSString *s, UInt32 *key, UInt32 *mods);
NSString *comboString(UInt32 key, UInt32 mods, BOOL pretty);
void rfRegister(Binding *b);
void rfUnregister(Binding *b);
void rfSaveConfig(void);
void rfReloadConfigIfChanged(void);
void rfOpenApp(NSString *path, BOOL fromHotkey);
void rfRespawn(void);

// ---- ui.m
void uiRun(void);       // starts AppKit, builds and pre-shows the hidden window, runs the event loop; never returns
void uiToggle(void);
void uiSnapshot(void);
int uiEval(int argc, const char **argv);

// ---- codex.m: one `codex exec` process per turn, nothing running between turns
extern NSString *cxStatus, *cxAnswer, *cxError;   // current turn: progress line, latest answer, failure message
extern void (^cxChanged)(void);                    // called on the main thread whenever one of those changes
BOOL cxBusy(void);
double cxStartedAt(void);                          // CFAbsoluteTime the running turn started
NSString *cxModel(void);
void cxSend(NSString *prompt);                     // first call starts a thread, later calls resume it
void cxReset(void);                                // kills a running turn and forgets the thread
NSArray<NSAttributedString *> *cxMarkdown(NSString *md);   // blocks; code blocks carry the attribute CX_CODE
#define CX_CODE @"rfCode"
