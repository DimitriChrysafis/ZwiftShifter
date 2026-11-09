// Read-only observation of values Zwift already receives from a KICKR.
// Run through observe.py for bounded lifetime and guaranteed detach. No BLE
// connections, subscriptions, characteristic writes, or game state changes.
const lookup = new NativeFunction(Module.getGlobalExportByName('objc_getClass'), 'pointer', ['pointer']);
const selector = new NativeFunction(Module.getGlobalExportByName('sel_registerName'), 'pointer', ['pointer']);
const getMethod = new NativeFunction(Module.getGlobalExportByName('class_getInstanceMethod'), 'pointer', ['pointer', 'pointer']);
const getImp = new NativeFunction(Module.getGlobalExportByName('method_getImplementation'), 'pointer', ['pointer']);
const msg = new NativeFunction(Module.getGlobalExportByName('objc_msgSend'), 'pointer', ['pointer', 'pointer']);
const cls = lookup(Memory.allocUtf8String('_TtC14ble_middleware17SwiftBLEInterface'));
function sel(name) { return selector(Memory.allocUtf8String(name)); }
const selectors = Object.fromEntries(['name', 'UUID', 'UUIDString', 'UTF8String', 'value', 'length', 'bytes'].map(n => [n, sel(n)]));
function get(object, name) { return msg(object, selectors[name]); }
function string(object) { return object.isNull() ? '' : get(object, 'UTF8String').readUtf8String(); }
const counts = {};
const last = {};
const method = cls.isNull() ? ptr(0) : getMethod(cls, sel('peripheral:didUpdateValueForCharacteristic:error:'));
if (method.isNull()) throw new Error('Expected BLE callback is absent; no hook installed.');
Interceptor.attach(getImp(method), {
    onEnter(args) {
        try {
            if (!args[4].isNull() || !string(get(args[2], 'name')).startsWith('KICKR CORE')) return;
            const uuid = string(get(get(args[3], 'UUID'), 'UUIDString')).toUpperCase();
            counts[uuid] = (counts[uuid] || 0) + 1;
            if (!['2A63', '2AD2', '2A5B', '00000002-19CA-4651-86E5-FA29DCDD09D1'].includes(uuid)) return;
            const now = Date.now();
            if (now - (last[uuid] || 0) < 1000) return;
            last[uuid] = now;
            const data = get(args[3], 'value');
            if (data.isNull()) return;
            const length = get(data, 'length').toUInt32();
            const bytes = get(data, 'bytes');
            const hex = Array.from(new Uint8Array(bytes.readByteArray(Math.min(length, 64))))
                .map(b => b.toString(16).padStart(2, '0')).join('');
            const row = {event: 'trainer-value', time: now, uuid, length, hex};
            if (uuid === '2A63' && length >= 4) row.watts = bytes.add(2).readS16();
            send(row);
        } catch (error) { send({event: 'observer-error', message: String(error)}); }
    }
});
send({event: 'observing-existing-trainer-notifications'});
setInterval(() => send({event: 'notification-counts', counts}), 5000);
