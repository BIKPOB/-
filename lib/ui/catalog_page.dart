import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import '../core/profile_policy.dart';
import 'public_catalog_page.dart';
import '../platform/config_browser.dart';
import '../viewmodels/vpn_view_model.dart';

const protocols = {'wireguard':'WireGuard', 'vless':'VLESS', 'shadowsocks':'Shadowsocks'};
class CatalogPage extends StatelessWidget {
  const CatalogPage(this.vm, {super.key});
  final VpnViewModel vm;
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Добавить сервер')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: ListView(padding: const EdgeInsets.all(16), children: [
      FilledButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PublicCatalogPage(vm))), icon: const Icon(Icons.public), label: const Text('Публичные серверы VLESS / Shadowsocks')),
      const SizedBox(height: 16),
      Text('Добавить свой сервер', style: Theme.of(context).textTheme.headlineSmall),
      const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Сайт открывается прямо в приложении: можно войти, выбрать регион и получить конфигурацию. Для подключения нужны действующие данные от владельца сервера.')),
      for (final entry in protocols.entries) Card(child: Padding(padding: const EdgeInsets.all(8), child: ListTile(
        leading: Icon(entry.key == 'wireguard' ? Icons.shield_outlined : entry.key == 'vless' ? Icons.lock_outline : Icons.cloud_outlined),
        title: Text(entry.value), subtitle: Text(switch(entry.key) {
          'wireguard' => 'Файл .conf или параметры WireGuard', 'vless' => 'Ключ vless:// · TCP, TLS/REALITY, WS, gRPC, XHTTP',
          _ => 'Ключ ss:// · AEAD / Shadowsocks 2022'}), trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AddServerPage(vm, entry.key)))))),
    ]))));
}
class AddServerPage extends StatefulWidget {
  const AddServerPage(this.vm, this.protocol, {super.key});
  final VpnViewModel vm;
  final String protocol;
  @override State<AddServerPage> createState() => _AddServerPageState();
}
class _AddServerPageState extends State<AddServerPage> {
  final fields = <String, TextEditingController>{};
  String security = 'reality', transport = 'tcp', cipher = 'chacha20-ietf-poly1305';
  bool busy = false;
  String? error;
  TextEditingController c(String name, [String initial = '']) => fields.putIfAbsent(name, () => TextEditingController(text: initial));
  String v(String name) => c(name).text.trim();
  @override void dispose() { for(final controller in fields.values) { controller.dispose(); } super.dispose(); }
  Widget field(String name, String label, {String initial = '', bool secret = false, int lines = 1, String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom:12), child: TextField(controller:c(name,initial), obscureText:secret,
      autocorrect:false, enableSuggestions:false, minLines:lines, maxLines:lines, maxLength:lines>1 ? ProfilePolicy.maxBytes : 4096,
      decoration:InputDecoration(labelText:label, hintText:hint, border:const OutlineInputBorder(), counterText:'')));
  Future<void> receive(String text) async {
    setState(() {busy=true;error=null;});
    try {
      final parsed = ProfilePolicy.parse(text);
      if (parsed.protocol != widget.protocol) throw FormatException('Получен ${protocols[parsed.protocol]}. Откройте карточку этого протокола.');
      if (!mounted) return;
      final accepted = await showDialog<bool>(context:context,builder:(context)=>AlertDialog(title:const Text('Добавить сервер?'),
        content:Text('${protocols[parsed.protocol]}\n${parsed.host}:${parsed.port}\nКлюч будет сохранён в защищённом хранилище.'),
        actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Отмена')),
          FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Добавить'))]));
      if (accepted != true) return;
      await widget.vm.importProfile(parsed.text,v('name').isEmpty ? '${protocols[parsed.protocol]} · ${parsed.host}' : v('name'),v('region'));
      if (mounted) Navigator.popUntil(context,(route)=>route.isFirst);
    } catch(e) { if(mounted) setState(()=>error=e is FormatException ? e.message : 'Не удалось добавить сервер'); }
    finally {if(mounted)setState(()=>busy=false);}
  }
  Future<void> browse({bool vpnbook=false}) async {
    try {
      final url = v('url');
      if(!vpnbook) {
        final uri=Uri.tryParse(url);
        if(uri==null||uri.scheme!='https'||uri.host.isEmpty||uri.userInfo.isNotEmpty) throw const FormatException('Введите HTTPS-адрес сайта выдачи конфигураций');
      }
      final text=await ConfigBrowser.open(vpnbook?'vpnbook':'custom',url:vpnbook?null:url);
      if(text!=null&&mounted) await receive(text);
    } catch(e) {if(mounted)setState(()=>error=e is FormatException?e.message:'Не удалось открыть сайт');}
  }
  Future<void> file() async {
    try {
      final picked=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['conf','txt'],withData:false);
      if(picked==null)return;
      final selected=picked.files.single;
      if(selected.path==null||selected.size>ProfilePolicy.maxBytes)throw const FormatException('Файл должен быть не больше 128 КБ');
      final f=File(selected.path!);
      if(await f.length()>ProfilePolicy.maxBytes)throw const FormatException('Файл слишком большой');
      final text=utf8.decode(await f.readAsBytes());
      if(mounted)await receive(text);
    }catch(e){if(mounted)setState(()=>error=e is FormatException?e.message:'Не удалось прочитать файл');}
  }
  Future<void> manual() async {
    try {
      final host=v('host'), port=int.tryParse(v('port'))??0;
      if(!ProfilePolicy.validHost(host)||port<1||port>65535)throw const FormatException('Проверьте адрес и порт сервера');
      String text;
      if(widget.protocol=='wireguard') {
        text='[Interface]\nPrivateKey = ${v('private')}\nAddress = ${v('address')}\nDNS = ${v('dns')}\n'
          '[Peer]\nPublicKey = ${v('public')}\n${v('psk').isEmpty?'':'PresharedKey = ${v('psk')}\n'}'
          'AllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = ${host.contains(':')?'[$host]':host}:$port\nPersistentKeepalive = 25\n';
      } else if(widget.protocol=='shadowsocks') {
        text=Uri(scheme:'ss',host:host,port:port,userInfo:base64Url.encode(utf8.encode('$cipher:${c('password').text}')).replaceAll('=','')).toString();
      } else {
        text=Uri(scheme:'vless',host:host,port:port,userInfo:v('uuid'),queryParameters:{
          'type':transport,'security':security,'encryption':'none',
          if(security!='none')'sni':v('sni'),if(security!='none')'fp':'chrome',
          if(security=='reality')'pbk':v('pbk'),if(security=='reality')'sid':v('sid'),
          if(v('flow').isNotEmpty)'flow':v('flow'),
          if(transport=='ws'||transport=='xhttp')'path':v('path'),
          if(transport=='ws'||transport=='xhttp')'host':v('httpHost'),
          if(transport=='grpc')'serviceName':v('service'),
        }).toString();
      }
      await receive(text);
    }catch(e){if(mounted)setState(()=>error=e is FormatException?e.message:'Проверьте поля конфигурации');}
  }
  Widget choice(String label, String value, List<String> values, void Function(String) update) => Padding(
    padding:const EdgeInsets.only(bottom:12),child:DropdownButtonFormField<String>(value:value,isExpanded:true,
      decoration:InputDecoration(labelText:label,border:const OutlineInputBorder()),
      items:values.map((s)=>DropdownMenuItem(value:s,child:Text(s))).toList(),onChanged:(s){if(s!=null)setState(()=>update(s));}));
  @override Widget build(BuildContext context) => DefaultTabController(length:3,child:Scaffold(
    appBar:AppBar(title:Text(protocols[widget.protocol]!),bottom:const TabBar(tabs:[Tab(text:'Браузер'),Tab(text:'Ключ / файл'),Tab(text:'Параметры')])),
    body:Column(children:[
      if(busy)const LinearProgressIndicator(),
      if(error!=null)Padding(padding:const EdgeInsets.all(12),child:Text(error!,style:TextStyle(color:Theme.of(context).colorScheme.error))),
      Expanded(child:AbsorbPointer(absorbing:busy,child:TabBarView(children:[
        ListView(padding:const EdgeInsets.all(16),children:[
          const Text('Откройте сайт, выполните вход и выберите сервер. Нажмите ссылку подключения, скачайте .conf или используйте «Импорт со страницы» в окне браузера.'),
          const SizedBox(height:16),
          if(widget.protocol=='wireguard')FilledButton.icon(onPressed:()=>browse(vpnbook:true),icon:const Icon(Icons.language),label:const Text('Открыть VPNBook · выдача WireGuard')),
          const SizedBox(height:16),field('url','Сайт выдачи VPN-конфигураций (необязательно)',hint:'https://…'),
          FilledButton.icon(onPressed:browse,icon:const Icon(Icons.open_in_browser),label:const Text('Открыть интерактивный браузер')),
          const SizedBox(height:12),const Text('Браузер использует Android System WebView: доступны вход, кнопки сайта, выбор региона, назад и обновление. Готовые VLESS/Shadowsocks доступны в разделе «Публичные серверы» на предыдущем экране.'),
        ]),
        ListView(padding:const EdgeInsets.all(16),children:[
          field('key',widget.protocol=='wireguard'?'Текст .conf':'Ссылка подключения',lines:7,hint:widget.protocol=='wireguard'?'[Interface]…':widget.protocol=='vless'?'vless://…':'ss://…'),
          Wrap(spacing:8,children:[OutlinedButton.icon(onPressed:()async{final data=await Clipboard.getData(Clipboard.kTextPlain);if(mounted)c('key').text=data?.text??'';},icon:const Icon(Icons.content_paste),label:const Text('Из буфера')),
            OutlinedButton.icon(onPressed:file,icon:const Icon(Icons.file_open_outlined),label:const Text('Из файла'))]),
          const SizedBox(height:12),FilledButton(onPressed:()=>receive(c('key').text),child:const Text('Проверить и добавить')),
        ]),
        ListView(padding:const EdgeInsets.all(16),children:[
          field('name','Название сервера (необязательно)'),field('region','Регион (необязательно)'),
          field('host','Адрес сервера'),field('port','Порт',initial:widget.protocol=='wireguard'?'51820':'443'),
          if(widget.protocol=='wireguard')...[
            field('private','Ваш PrivateKey',secret:true),field('address','Адрес в туннеле (CIDR)',hint:'10.0.0.2/32'),
            field('dns','DNS',initial:'1.1.1.1'),field('public','PublicKey сервера'),field('psk','PresharedKey (необязательно)',secret:true),
          ] else if(widget.protocol=='shadowsocks')...[
            choice('Шифр',cipher,['chacha20-ietf-poly1305','aes-128-gcm','aes-256-gcm','2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm','2022-blake3-chacha20-poly1305'],(s)=>cipher=s),field('password','Пароль',secret:true),
          ] else ...[
            field('uuid','UUID',secret:true),choice('Транспорт',transport,['tcp','ws','grpc','xhttp'],(s)=>transport=s),
            choice('Защита',security,['reality','tls','none'],(s)=>security=s),
            if(security!='none')field('sni','SNI сервера'),
            if(security=='reality')...[field('pbk','Public key REALITY'),field('sid','Short ID')],
            field('flow','Flow (необязательно)',hint:'xtls-rprx-vision'),
            if(transport=='ws'||transport=='xhttp')...[field('path','Path',initial:'/'),field('httpHost','HTTP Host (необязательно)')],
            if(transport=='grpc')field('service','Service name'),
          ],
          FilledButton(onPressed:manual,child:const Text('Проверить и добавить сервер')),
        ]),
      ]))),
    ])));
}
