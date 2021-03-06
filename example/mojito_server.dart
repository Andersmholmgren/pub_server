// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:mojito/mojito.dart';
import 'package:pub_server/mojito_pubserver.dart';

import 'src/examples/cow_repository.dart';
import 'src/examples/file_repository.dart';
import 'src/examples/http_proxy_repository.dart';

final Uri PubDartLangOrg = Uri.parse('https://pub.dartlang.org');

main(List<String> args) {
  var parser = argsParser();
  var results = parser.parse(args);

  var directory = results['directory'];
  var host = results['host'];
  var port = int.parse(results['port']);

  if (results.rest.length > 0) {
    print('Got unexpected arguments: "${results.rest.join(' ')}".\n\nUsage:\n');
    print(parser.usage);
    exit(1);
  }

  runPubServer(directory, host, port);
}

runPubServer(String baseDir, String host, int port) async {
  var client = new http.Client();

  var local = new FileRepository(baseDir);
  var remote = new HttpProxyRepository(client, PubDartLangOrg);
  var cow = new CopyAndWriteRepository(local, remote);

  print('Listening on http://$host:$port\n'
      '\n'
      'To make the pub client use this repository configure your shell via:\n'
      '\n'
      '    \$ export PUB_HOSTED_URL=http://$host:$port\n'
      '\n');
  final app = init();

  app.router.addAll(createPubApiResource(cow));

  app.start(port: port, address: (await InternetAddress.lookup(host)).first);
}

ArgParser argsParser() {
  var parser = new ArgParser();

  parser.addOption('directory',
      abbr: 'd', defaultsTo: 'pub_server-repository-data');

  parser.addOption('host', abbr: 'h', defaultsTo: 'localhost');

  parser.addOption('port', abbr: 'p', defaultsTo: '8080');
  return parser;
}
