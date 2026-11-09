// Read-only observation, specific to the documented 1.125 arm64 build.
const base = Process.getModuleByName('ZwiftAppSilicon').base;
for (const [offset, name] of [
  [0x16c7f48, 'shift_up_pressed'], [0x16c8098, 'shift_up_released'],
  [0x16c83e4, 'shift_down_pressed'], [0x16c8534, 'shift_down_released'],
  [0x183b13c, 'gearing_cassette'], [0x183b568, 'gearing_dispatch']
]) {
  Interceptor.attach(base.add(offset), {
    onEnter(args) {
      send({event: name, direction: args[1].toInt32(), count: args[2].toInt32(),
            state: args[3].toString(), time: Date.now(),
            stack: name === 'gearing_cassette' ? Thread.backtrace(this.context, Backtracer.ACCURATE)
              .slice(0, 12).map(p => p.sub(base).toString()) : []});
    }
  });
}
send({event: 'attached', base: base.toString()});
