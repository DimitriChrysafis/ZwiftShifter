#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

#import <stdatomic.h>

#if __has_feature(objc_arc)
#define BRIDGE_ARC 1
#endif

typedef void (*BridgeEventIMP)(id, SEL, id, id, id, uint64_t, id, int64_t);

static BridgeEventIMP originalEvent;
static Method bridgeMethod;
static SEL eventSelector;
static atomic_bool hookInstalled = false;
static atomic_bool receiverCaptured = false;
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static __strong id bridgeReceiver;
static char requestedPeripheralID[64];
static char socketPath[sizeof(((struct sockaddr_un *)0)->sun_path)];

static void SendShift(char command, const char *peripheralID) {
    id receiver;
    pthread_mutex_lock(&stateLock);
    receiver = bridgeReceiver;
    pthread_mutex_unlock(&stateLock);
    if (!receiver || !originalEvent || !peripheralID[0]) return;

    const unsigned char easier[] = {0x23, 0x08, 0xff, 0xfb, 0xff, 0xff, 0x0f};
    const unsigned char harder[] = {0x23, 0x08, 0xff, 0xdf, 0xff, 0xff, 0x0f};
    const unsigned char released[] = {0x23, 0x08, 0xff, 0xff, 0xff, 0xff, 0x0f};
    const unsigned char *bytes = command == 'U' ? harder : easier;
    @autoreleasepool {
        NSString *peripheral = [[NSString alloc] initWithUTF8String:peripheralID];
        NSData *press = [NSData dataWithBytes:bytes length:sizeof(easier)];
        NSData *release = [NSData dataWithBytes:released length:sizeof(released)];
        originalEvent(receiver, eventSelector, peripheral, @"FC82", @"00000002-19CA-4651-86E5-FA29DCDD09D1", 16, press, press.length);
        usleep(80000);
        originalEvent(receiver, eventSelector, peripheral, @"FC82", @"00000002-19CA-4651-86E5-FA29DCDD09D1", 16, release, release.length);
        usleep(80000);
    }
}

static void CaptureEvent(id receiver, SEL selector, id peripheral, id service, id characteristic, uint64_t flags, id value, int64_t length) {
    if (!atomic_exchange(&receiverCaptured, true)) {
        pthread_mutex_lock(&stateLock);
        bridgeReceiver = receiver;
        pthread_mutex_unlock(&stateLock);
        method_setImplementation(bridgeMethod, (IMP)originalEvent);
    }
    originalEvent(receiver, selector, peripheral, service, characteristic, flags, value, length);
}

static char CurrentStatus(void) {
    if (!atomic_load(&hookInstalled)) return 'E';
    return atomic_load(&receiverCaptured) ? 'R' : 'W';
}

static void HandleClient(int client) {
    char message[128] = {0};
    ssize_t count = read(client, message, sizeof(message) - 1);
    if (count > 0 && (message[0] == 'U' || message[0] == 'D')) {
        char peripheralID[64] = {0};
        if (count > 2 && message[1] == '|') {
            size_t length = (size_t)count - 2;
            if (length >= sizeof(peripheralID)) length = sizeof(peripheralID) - 1;
            memcpy(peripheralID, message + 2, length);
            peripheralID[length] = 0;
        }
        pthread_mutex_lock(&stateLock);
        if (peripheralID[0]) strlcpy(requestedPeripheralID, peripheralID, sizeof(requestedPeripheralID));
        char selectedID[64];
        strlcpy(selectedID, requestedPeripheralID, sizeof(selectedID));
        pthread_mutex_unlock(&stateLock);
        SendShift(message[0], selectedID);
    }
    char status = CurrentStatus();
    write(client, &status, 1);
    close(client);
}

static void *SocketServer(void *unused) {
    snprintf(socketPath, sizeof(socketPath), "/tmp/zwift-shifter-%u.sock", getuid());
    unlink(socketPath);
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return NULL;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path, socketPath, sizeof(address.sun_path));
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 8) != 0) {
        close(server);
        return NULL;
    }
    chmod(socketPath, 0600);
    while (1) {
        int client = accept(server, NULL, NULL);
        if (client >= 0) HandleClient(client);
    }
    return NULL;
}

static void *InstallHook(void *unused) {
    eventSelector = sel_registerName("addCharacteristicNotificationEvent:serviceId:characteristicId:characteristicFlags:value:length:");
    while (!atomic_load(&hookInstalled)) {
        Class bridgeClass = objc_getClass("BridgeInterface");
        bridgeMethod = bridgeClass ? class_getInstanceMethod(bridgeClass, eventSelector) : NULL;
        if (bridgeMethod) {
            originalEvent = (BridgeEventIMP)method_getImplementation(bridgeMethod);
            method_setImplementation(bridgeMethod, (IMP)CaptureEvent);
            atomic_store(&hookInstalled, originalEvent != NULL);
            break;
        }
        usleep(100000);
    }
    return NULL;
}

__attribute__((constructor)) static void StartBridge(void) {
    pthread_t hookThread;
    pthread_t socketThread;
    pthread_create(&hookThread, NULL, InstallHook, NULL);
    pthread_detach(hookThread);
    pthread_create(&socketThread, NULL, SocketServer, NULL);
    pthread_detach(socketThread);
}

__attribute__((destructor)) static void StopBridge(void) {
    if (socketPath[0]) unlink(socketPath);
}
