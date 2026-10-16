"""Fail-closed lifecycle patches for the pinned VPN backends (minimum API 26)."""

def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError('Pinned VPN lifecycle changed: expected exactly one patch site')
    return source.replace(old, new, 1)


def notification_method(channel, notification_id, label):
    return '''
    // Quiet VPN: foreground before native initialization or publishing readiness.
    private void quietStartForeground() {
        android.app.NotificationManager manager = getSystemService(android.app.NotificationManager.class);
        String channel = "%s";
        manager.createNotificationChannel(new android.app.NotificationChannel(channel,
            "Quiet VPN", android.app.NotificationManager.IMPORTANCE_LOW));
        android.app.Notification.Builder notification = new android.app.Notification.Builder(this, channel)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("Quiet VPN")
            .setContentText("%s")
            .setOngoing(true);
        android.content.Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) notification.setContentIntent(android.app.PendingIntent.getActivity(this,
            %d, launch, android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT));
        startForeground(%d, notification.build());
    }
''' % (channel, label, notification_id, notification_id)


def patch_xray(source):
    if '// Quiet VPN: foreground before' in source:
        if '.cancel(5353)' not in source:
            source = source.replace('        stopForeground(true);', '        getSystemService(android.app.NotificationManager.class).cancel(5353);\n        stopForeground(true);')
        return source
    source = replace_once(source, '        super.onCreate();\n        V2rayCoreManager.getInstance().setUpListener(this);',
        '        super.onCreate();\n        quietStartForeground();\n        V2rayCoreManager.getInstance().setUpListener(this);')
    source = replace_once(source, '    public int onStartCommand(Intent intent, int flags, int startId) {',
        notification_method('quietvpn_start', 1, 'Запуск VPN') + '\n    public int onStartCommand(Intent intent, int flags, int startId) {\n        quietStartForeground();')
    # The inserted helper must not take onStartCommand's @Override annotation.
    source = replace_once(source, '    @Override\n\n    // Quiet VPN:', '    // Quiet VPN:')
    source = replace_once(source, '\n    public int onStartCommand(', '\n    @Override\n    public int onStartCommand(')
    if 'this.onDestroy();' not in source:
        raise ValueError('Pinned Xray failure cleanup changed')
    source = source.replace('this.onDestroy();', 'stopSelf();')
    source = replace_once(source, '            AppConfigs.V2RAY_CONFIG = null;',
        '            AppConfigs.V2RAY_CONFIG = null;\n            stopSelf();')
    source = source.replace('        stopForeground(true);',
        '        getSystemService(android.app.NotificationManager.class).cancel(5353);\n        stopForeground(true);')
    return source.replace('return START_STICKY;', 'return START_NOT_STICKY;')


def patch_awg(source):
    if '// Quiet VPN: foreground before' in source:
        if '.cancel(5353)' not in source:
            source = replace_once(source, '            vpnService = vpnService.newIncompleteFuture();', '            getSystemService(android.app.NotificationManager.class).cancel(5353);\n            vpnService = vpnService.newIncompleteFuture();')
        return source
    old = 'context.startService(new Intent(context, VpnService.class));'
    source = replace_once(source, old,
        'if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(new Intent(context, VpnService.class)); else ' + old)
    source = replace_once(source,
        '            vpnService.complete(this);\n            super.onCreate();',
        '            super.onCreate();\n            quietStartForeground();\n            vpnService.complete(this);')
    source = replace_once(source, '            vpnService.complete(this);\n            if (intent == null',
        '            quietStartForeground();\n            vpnService.complete(this);\n            if (intent == null')
    source = replace_once(source, '        public void setOwner(final GoBackend owner) {',
        notification_method('quietvpn_wg', 5252, 'WireGuard / AmneziaWG') + '\n        public void setOwner(final GoBackend owner) {')
    source = replace_once(source, '            vpnService = vpnService.newIncompleteFuture();',
        '            getSystemService(android.app.NotificationManager.class).cancel(5353);\n            vpnService = vpnService.newIncompleteFuture();')
    return replace_once(source, 'return super.onStartCommand(intent, flags, startId);', 'return START_NOT_STICKY;')
