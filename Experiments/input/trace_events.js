// Observe Cocoa/GLFW event delivery only. All hooks disappear on detach.
const lookup = new NativeFunction(Module.getGlobalExportByName('objc_getClass'), 'pointer', ['pointer']);
const selector = new NativeFunction(Module.getGlobalExportByName('sel_registerName'), 'pointer', ['pointer']);
const getMethod = new NativeFunction(Module.getGlobalExportByName('class_getInstanceMethod'), 'pointer', ['pointer', 'pointer']);
const getImp = new NativeFunction(Module.getGlobalExportByName('method_getImplementation'), 'pointer', ['pointer']);
const msg = new NativeFunction(Module.getGlobalExportByName('objc_msgSend'), 'pointer', ['pointer', 'pointer']);
const point = new NativeFunction(Module.getGlobalExportByName('objc_msgSend'), ['double', 'double'], ['pointer', 'pointer']);
function cls(s) { return lookup(Memory.allocUtf8String(s)); }
function sel(s) { return selector(Memory.allocUtf8String(s)); }
const app = msg(cls('NSApplication'), sel('sharedApplication'));
send({event: 'mouseLocation', point: point(cls('NSEvent'), sel('mouseLocation')), keyWindow: msg(app, sel('keyWindow'))});
const msgIndex = new NativeFunction(Module.getGlobalExportByName('objc_msgSend'), 'pointer', ['pointer', 'pointer', 'ulong']);
const rect = new NativeFunction(Module.getGlobalExportByName('objc_msgSend'), [['double', 'double'], ['double', 'double']], ['pointer', 'pointer']);
const windows = msg(app, sel('windows'));
const count = msg(windows, sel('count')).toInt32();
for (let i=0; i<Math.min(count, 8); i++) {
    const w = msgIndex(windows, sel('objectAtIndex:'), i);
    send({event:'window', window:w, frame:rect(w,sel('frame')), number:msg(w,sel('windowNumber')).toInt32()});
}
for (const name of ['mouseDown:', 'mouseUp:', 'mouseMoved:', 'keyDown:', 'keyUp:']) {
    const method = getMethod(cls('GLFWContentView'), sel(name));
    if (method.isNull()) continue;
    Interceptor.attach(getImp(method), {
        onEnter(args) {
            send({event: name, point: point(args[2], sel('locationInWindow')),
                  mouseLocation: point(cls('NSEvent'), sel('mouseLocation'))});
        }
    });
}
