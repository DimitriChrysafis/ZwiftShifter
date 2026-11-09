// Observe nanopb failures only. No return values or data are modified.
const base = Process.getModuleByName('ZwiftAppSilicon').base;
let failures = 0;
Interceptor.attach(base.add(0x1db1ab0), {
  onEnter(args) {
    this.stream = args[0];
    this.descriptor = args[1];
  },
  onLeave(result) {
    if (result.toInt32() !== 0 || failures++ > 40) return;
    try {
      const error = this.stream.add(24).readPointer();
      send({event: 'decode_failure', descriptor: this.descriptor.sub(base).toString(),
            error: error.isNull() ? null : error.readCString(),
            remaining: this.stream.add(16).readU64().toString()});
    } catch (error) { send({event: 'inspection_error', error: String(error)}); }
  }
});
send({event: 'attached', base: base.toString()});
