// Standalone feasibility probe; not included in Runbar. Uses only a private
// loopback fixture, keeps VM authentication enabled, and never contacts a user app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as developer;

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--fixture')) { await fixture(); return; }
  final destination = Directory(arguments.isEmpty ? '.build/devtools-network-probe' : arguments.first);
  await destination.create(recursive: true);
  final vm = File(Platform.resolvedExecutable).parent.uri.resolve('dartvm').toFilePath();
  final executable = await File(vm).exists() ? vm : Platform.resolvedExecutable;
  final child = await Process.start(executable, ['--enable-vm-service=0', Platform.script.toFilePath(), '--fixture']);
  final serviceReady = Completer<Uri>(), controlReady = Completer<int>();
  final subscription = child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    if (line.startsWith('VM_ENDPOINT=') && !serviceReady.isCompleted) { serviceReady.complete(Uri.parse(line.substring(12))); }
    if (line.startsWith('CONTROL_PORT=') && !controlReady.isCompleted) { controlReady.complete(int.parse(line.substring(13))); }
  });
  // Consume without forwarding service URLs or tokens to the transcript.
  final errors = child.stderr.listen((_) {});
  child.exitCode.then((_) {
    if (!serviceReady.isCompleted) { serviceReady.completeError(StateError('This Dart executable has no VM service; use an SDK with dartvm.')); }
  });
  final client = HttpClient();
  Uri? service;
  Future<Map<String, dynamic>> get(Uri url) async {
    final request = await client.getUrl(url);
    final response = await request.close();
    final value = jsonDecode(await utf8.decodeStream(response));
    if (value is! Map<String, dynamic>) { throw StateError('Unexpected response'); }
    return value;
  }
  try {
    service = await serviceReady.future.timeout(const Duration(seconds: 20));
    final port = await controlReady.future.timeout(const Duration(seconds: 20));
    Future<Map<String, dynamic>> rpc(String method, [Map<String, String> params = const {}]) async {
      final envelope = await get(service!.resolve(method).replace(queryParameters: params));
      if (envelope['error'] != null) { throw StateError('RPC $method failed: ${envelope['error']}'); }
      return envelope['result'] as Map<String, dynamic>;
    }
    final vm = await rpc('getVM');
    final isolates = vm['isolates'] as List;
    final isolate = (isolates.firstWhere((value) => value['name'] == 'main', orElse: () => isolates.first))['id'] as String;
    final params = {'isolateId': isolate};
    await rpc('ext.dart.io.httpEnableTimelineLogging', {...params, 'enabled': 'true'});
    await get(Uri.parse('http://127.0.0.1:$port/trigger?value=first'));
    final first = await rpc('ext.dart.io.getHttpProfile', params);
    final firstRequests = (first['requests'] as List).where((value) => (value['uri'] as String).contains('/echo')).toList();
    if (firstRequests.length != 1) { throw StateError('Expected first profiled request'); }
    final detail = await rpc('ext.dart.io.getHttpProfileRequest', {...params, 'id': firstRequests.first['id'].toString()});
    final requestBody = utf8.decode((detail['requestBody'] as List).cast<int>());
    final responseBody = utf8.decode((detail['responseBody'] as List).cast<int>());
    if (detail['response']['statusCode'] != 200 || !requestBody.contains('first') || !responseBody.contains('first')) {
      throw StateError('Missing HTTP status or bodies');
    }
    await get(Uri.parse('http://127.0.0.1:$port/trigger?value=second'));
    final next = await rpc('ext.dart.io.getHttpProfile', {...params, 'updatedSince': first['timestamp'].toString()});
    final nextRequests = (next['requests'] as List).where((value) => (value['uri'] as String).contains('/echo')).toList();
    if (!nextRequests.any((value) => value['id'] != detail['id'])) { throw StateError('Incremental profile missing new request'); }
    final sink = File('${destination.path}/requests.jsonl').openWrite();
    sink.writeln(jsonEncode(detail));
    for (final request in nextRequests) { sink.writeln(jsonEncode(request)); }
    await sink.close();
    final cached = await File('${destination.path}/requests.jsonl').readAsLines();
    if (cached.length < 2) { throw StateError('Cache not persisted'); }
    final summary = {'dart': Platform.version.split(' ').first, 'httpStatus': 200, 'requestBodyVerified': true,
      'responseBodyVerified': true, 'incrementalReadVerified': true, 'cachedRecords': cached.length,
      'onlyLoopbackFixture': true};
    await File('${destination.path}/summary.json').writeAsString(const JsonEncoder.withIndent('  ').convert(summary));
    stdout.writeln(jsonEncode(summary));
    await get(Uri.parse('http://127.0.0.1:$port/stop'));
    await child.exitCode.timeout(const Duration(seconds: 5));
  } catch (error) {
    stderr.writeln(service == null ? 'VM service probe failed before connection: ${error.runtimeType}' : error.toString().replaceAll(service.toString(), '<private VM service>'));
    exitCode = 1;
  } finally {
    client.close(force: true); child.kill(); await subscription.cancel(); await errors.cancel();
  }
}

Future<void> fixture() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient(), stopped = Completer<void>();
  server.listen((request) async {
    request.response.headers.contentType = ContentType.json;
    if (request.uri.path == '/oversized') {
      request.response.contentLength = 10000;
      request.response.write('x' * 10000);
    } else if (request.uri.path == '/redirect') {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, 'http://not-used.invalid/');
    } else if (request.uri.path == '/echo') {
      final body = await utf8.decodeStream(request);
      request.response.write(jsonEncode({'echo': body}));
    } else if (request.uri.path == '/trigger') {
      final call = await client.postUrl(Uri.parse('http://127.0.0.1:${server.port}/echo'));
      call.headers.contentType = ContentType.json;
      call.write(jsonEncode({'probe': request.uri.queryParameters['value']}));
      final response = await call.close(); await response.drain<void>();
      request.response.write('{"ok":true}');
    } else if (request.uri.path == '/stop') {
      request.response.write('{"ok":true}');
      await request.response.close(); stopped.complete(); return;
    }
    await request.response.close();
  });
  for (var retry = 0; retry < 100; retry++) {
    final info = await developer.Service.getInfo();
    if (info.serverUri != null) { stdout.writeln('VM_ENDPOINT=${info.serverUri}'); break; }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  stdout.writeln('CONTROL_PORT=${server.port}');
  await stopped.future;
  client.close(force: true); await server.close(force: true);
}
