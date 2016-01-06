// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_server.mojito_pubserver;

import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf.dart';
import 'package:shelf_rest/shelf_rest.dart';
import 'package:yaml/yaml.dart';

import 'repository.dart';

final Logger _logger = new Logger('pubserver.mojito_pubserver');

// TODO: Error handling from [PackageRepo] class.
// Distinguish between:
//   - Unauthorized Error
//   - Version Already Exists Error
//   - Internal Server Error
/// A shelf handler for serving a pub [PackageRepository].
///
/// The following API endpoints are provided by this shelf handler:
///
///   * Getting information about all versions of a package.
///
///         GET /api/packages/<package-name>
///         [200 OK] [Content-Type: application/json]
///         {
///           "name" : "<package-name>",
///           "latest" : { ...},
///           "versions" : [
///             {
///               "version" : "<version>",
///               "archive_url" : "<download-url tar.gz>",
///               "pubspec" : {
///                 "author" : ...,
///                 "dependencies" : { ... },
///                 ...
///               },
///           },
///           ...
///           ],
///         }
///         or
///         [404 Not Found]
///
///   * Getting information about a specific (package, version) pair.
///
///         GET /api/packages/<package-name>/versions/<version-name>
///         [200 OK] [Content-Type: application/json]
///         {
///           "version" : "<version>",
///           "archive_url" : "<download-url tar.gz>",
///           "pubspec" : {
///             "author" : ...,
///             "dependencies" : { ... },
///             ...
///           },
///         }
///         or
///         [404 Not Found]
///
///   * Downloading package.
///
///         GET /api/packages/<package-name>/versions/<version-name>.tar.gz
///         [200 OK] [Content-Type: octet-stream ??? FIXME ???]
///         or
///         [302 Found / Temporary Redirect]
///         Location: <new-location>
///         or
///         [404 Not Found]
///
///   * Uploading
///
///         GET /api/packages/versions/new
///         Headers:
///           Authorization: Bearer <oauth2-token>
///         [200 OK]
///         {
///           "fields" : {
///               "a": "...",
///               "b": "...",
///               ...
///           },
///           "url" : "https://storage.googleapis.com"
///         }
///
///         POST "https://storage.googleapis.com"
///         Headers:
///           a: ...
///           b: ...
///           ...
///         <multipart> file package.tar.gz
///         [302 Found / Temporary Redirect]
///         Location: https://pub.dartlang.org/finishUploadUrl
///
///         GET https://pub.dartlang.org/finishUploadUrl
///         [200 OK]
///         {
///           "success" : {
///             "message": "Successfully uploaded package.",
///           },
///        }
///
///   * Adding a new uploader
///
///         POST /api/packages/<package-name>/uploaders
///         email=<uploader-email>
///
///         [200 OK] [Content-Type: application/json]
///         or
///         [400 Client Error]
///
///   * Removing an existing uploader.
///
///         DELETE /api/packages/<package-name>/uploaders/<uploader-email>
///         [200 OK] [Content-Type: application/json]
///         or
///         [400 Client Error]
///
///
/// It will use the pub [PackageRepository] given in the constructor to provide
/// this HTTP endpoint.
///
///
class PubApiResource extends _BaseApiResource {
  final PackagesResource _packagesResource;

  PubApiResource(PackageRepository repository, this._packagesResource,
      {PackageCache cache})
      : super(repository, cache);

  @AddAll(path: 'api/packages')
  PackagesResource packages() => _packagesResource;

  @Get('packages/{package}/versions/{version}.tar.gz')
  Future<shelf.Response> download(
      String package, String version, Request request) {
    if (!isSemanticVersion(version)) return _invalidVersion(version);
    return _download(request.requestedUri, package, version);
  }

  Future<shelf.Response> _download(Uri uri, String package, String version) {
    if (repository.supportsDownloadUrl) {
      return repository.downloadUrl(package, version).then((Uri url) {
        // This is a redirect to [url]
        return new shelf.Response.seeOther(url);
      });
    }
    return repository.download(package, version).then((stream) {
      return new shelf.Response.ok(stream);
    });
  }
}

@RestResource('package')
class PackagesResource extends _BaseApiResource {
  static final RegExp _boundaryRegExp = new RegExp(r'^.*boundary="([^"]+)"$');

  final VersionsResource _versionsResource;
  final UpLoadersResource _uploadersResource;

  PackagesResource(PackageRepository repository, this._versionsResource,
      this._uploadersResource,
      {PackageCache cache})
      : super(repository, cache);

  // forwards to the versions search. Not pretty
  @Get('{package}')
  Future<Response> searchVersions(String package, Request request) =>
      _versionsResource.search(package, request);

  @Get('versions/new')
  Future<Map> upload(Request request) {
    if (!repository.supportsUpload) {
      return new Future.value(new shelf.Response.notFound(null));
    }

    if (repository.supportsAsyncUpload) {
      return _startUploadAsync(request.requestedUri);
    } else {
      return _startUploadSimple(request.requestedUri);
    }
  }

  @Get('versions/newUploadFinish')
  Future<Response> newUploadFinish(Request request) {
    if (!repository.supportsUpload) {
      return new Future.value(new shelf.Response.notFound(null));
    }

    if (repository.supportsAsyncUpload) {
      return _finishUploadAsync(request.requestedUri);
    } else {
      return _finishUploadSimple(request.requestedUri);
    }
  }

  @Post('versions/newUpload')
  Future<Response> newUpload(Request request) {
    if (!repository.supportsUpload) {
      return new Future.value(new shelf.Response.notFound(null));
    }

    return _uploadSimple(
        request.requestedUri, request.headers['content-type'], request.read());
  }

  @AddAll(path: 'versions')
  VersionsResource versions() => _versionsResource;

  @AddAll(path: 'uploaders')
  UpLoadersResource upLoaders() => _uploadersResource;

  Future<Map> _startUploadAsync(Uri uri) async {
    final AsyncUploadInfo info =
        await repository.startAsyncUpload(_finishUploadAsyncUrl(uri));
    return {'url': '${info.uri}', 'fields': info.fields,};
  }

  Future<shelf.Response> _finishUploadAsync(Uri uri) async {
    try {
      final PackageVersion vers = await repository.finishAsyncUpload(uri);
      if (cache != null) {
        _logger.info('Invalidating cache for package ${vers.packageName}.');
        await cache.invalidatePackageData(vers.packageName);
      }
      return _jsonResponse({
        'success': {'message': 'Successfully uploaded package.',},
      });
    } catch (error, stack) {
      _logger.warning('An error occured while finishing upload', error, stack);
      return _jsonResponse({
        'error': {'message': '$error.',},
      }, status: 400);
    }
  }

// Upload custom handlers.

  Future<Map> _startUploadSimple(Uri url) async {
    _logger.info('Start simple upload.');
    return {'url': '${_uploadSimpleUrl(url)}', 'fields': {},};
  }

  Future<shelf.Response> _uploadSimple(
      Uri uri, String contentType, Stream<List<int>> stream) {
    _logger.info('Perform simple upload.');
    if (contentType.startsWith('multipart/form-data')) {
      var match = _boundaryRegExp.matchAsPrefix(contentType);
      if (match != null) {
        var boundary = match.group(1);

// We have to listen to all multiparts: Just doing `parts.first` will
// result in the cancelation of the subscription which causes
// eventually a destruction of the socket, this is an odd side-effect.
// What we would like to have is something like this:
//     parts.expect(1).then((part) { upload(part); })
        bool firstPartArrived = false;
        var completer = new Completer();
        var subscription;

        var parts = stream.transform(new MimeMultipartTransformer(boundary));
        subscription = parts.listen((MimeMultipart part) {
// If we get more than one part, we'll ignore the rest of the input.
          if (firstPartArrived) {
            subscription.cancel();
            return;
          }
          firstPartArrived = true;

// TODO: Ensure that `part.headers['content-disposition']` is
// `form-data; name="file"; filename="package.tar.gz`
          repository.upload(part).then((PackageVersion version) async {
            if (cache != null) {
              _logger.info(
                  'Invalidating cache for package ${version.packageName}.');
              await cache.invalidatePackageData(version.packageName);
            }
            _logger.info('Redirecting to found url.');
            return new shelf.Response.found(_finishUploadSimpleUrl(uri));
          }).catchError((error, stack) {
            _logger.warning('Error occured: $error\n$stack.');
// TODO: Do error checking and return error codes?
            return new shelf.Response.found(
                _finishUploadSimpleUrl(uri, error: error));
          }).then(completer.complete);
        });

        return completer.future;
      }
    }
    return _badRequest(
        'Upload must contain a multipart/form-data content type.');
  }

  Future<shelf.Response> _finishUploadSimple(Uri uri) {
    var error = uri.queryParameters['error'];
    _logger.info('Finish simple upload (error: $error).');
    if (error != null) {
      return _badRequest(error);
    }
    return _jsonResponse({
      'success': {'message': 'Successfully uploaded package.'}
    });
  }
}

@RestResource('version')
class VersionsResource extends _BaseApiResource {
  VersionsResource(PackageRepository repository, {PackageCache cache})
      : super(repository, cache);

  Future<shelf.Response> search(String package, Request request) =>
      _listVersions(request.requestedUri, package);

  Future<Response> find(String package, String version, Request request) {
    if (!isSemanticVersion(version)) return _invalidVersion(version);
    return _showVersion(request.requestedUri, package, version);
  }

  Future<shelf.Response> _listVersions(Uri uri, String package) async {
    if (cache != null) {
      var binaryJson = await cache.getPackageData(package);
      if (binaryJson != null) {
        return _binaryJsonResponse(binaryJson);
      }
    }

    return repository
        .versions(package)
        .toList()
        .then((List<PackageVersion> packageVersions) async {
      if (packageVersions.length == 0) {
        return new shelf.Response.notFound(null);
      }

      packageVersions.sort((a, b) => a.version.compareTo(b.version));

      // TODO: Add legacy entries (if necessary), such as version_url.
      Map packageVersion2Json(PackageVersion version) {
        return {
          'archive_url': '${_downloadUrl(
            uri, version.packageName, version.versionString)}',
          'pubspec': loadYaml(version.pubspecYaml),
          'version': version.versionString,
        };
      }

      var latestVersion = packageVersions.last;
      for (int i = packageVersions.length - 1; i >= 0; i--) {
        if (!packageVersions[i].version.isPreRelease) {
          latestVersion = packageVersions[i];
          break;
        }
      }

      // TODO: The 'latest' is something we should get rid of, since it's
      // duplicated in 'versions'.
      var binaryJson = JSON.encoder.fuse(UTF8.encoder).convert({
        'name': package,
        'latest': packageVersion2Json(latestVersion),
        'versions': packageVersions.map(packageVersion2Json).toList(),
      });
      if (cache != null) {
        await cache.setPackageData(package, binaryJson);
      }
      return _binaryJsonResponse(binaryJson);
    });
  }

  Future<shelf.Response> _showVersion(Uri uri, String package, String version) {
    return repository
        .lookupVersion(package, version)
        .then((PackageVersion version) {
      if (version == null) {
        return new shelf.Response.notFound('');
      }

      // TODO: Add legacy entries (if necessary), such as version_url.
      return _jsonResponse({
        'archive_url': '${_downloadUrl(
          uri, version.packageName, version.versionString)}',
        'pubspec': loadYaml(version.pubspecYaml),
        'version': version.versionString,
      });
    });
  }
}

@RestResource('userEmail')
class UpLoadersResource extends _BaseApiResource {
  UpLoadersResource(PackageRepository repository, {PackageCache cache})
      : super(repository, cache);

  Future<Response> create(
      String package, @RequestBody(format: ContentType.FORM) Map body) {
    if (!repository.supportsUploaders) {
      return new Future.value(new shelf.Response.notFound(null));
    }

    return _addUploader(package, body['email']);
  }

//  @Delete('{userEmail}')
  Future<Response> delete(String package, String userEmail) async {
    if (!repository.supportsUploaders) {
      return new Future.value(new shelf.Response.notFound(null));
    }

    try {
      await repository.removeUploader(package, userEmail);
      return _successfullRequest('Successfully removed uploader from package.');
    } on LastUploaderRemoveException {
      return _badRequest('Cannot remove last uploader of a package.');
    } on UnauthorizedAccessException {
      return _unauthorizedRequest();
    }
  }

  Future<shelf.Response> _addUploader(String package, String user) async {
    try {
      await repository.addUploader(package, user);
      return _successfullRequest('Successfully added uploader to package.');
    } on UploaderAlreadyExistsException {
      return _badRequest('Cannot add an already-existent uploader to package.');
    } on UnauthorizedAccessException {
      return _unauthorizedRequest();
    }

    return _badRequest('Invalid request');
  }
}

bool isSemanticVersion(String version) {
  try {
    new semver.Version.parse(version);
    return true;
  } catch (_) {
    return false;
  }
}

abstract class _BaseApiResource {
  final PackageRepository repository;
  final PackageCache cache;

  _BaseApiResource(this.repository, this.cache);
}

/// A cache for storing metadata for packages.
abstract class PackageCache {
  Future setPackageData(String package, List<int> data);

  Future<List<int>> getPackageData(String package);

  Future invalidatePackageData(String package);
}

// Helper functions.

Future<shelf.Response> _invalidVersion(String version) {
  return _badRequest(
      'Version string "$version" is not a valid semantic version.');
}

Future<shelf.Response> _successfullRequest(String message) {
  return new Future.value(new shelf.Response(200,
      body: JSON.encode({
        'success': {'message': message}
      }),
      headers: {'content-type': 'application/json'}));
}

Future<shelf.Response> _unauthorizedRequest() {
  return new Future.value(new shelf.Response(403,
      body: JSON.encode({
        'error': {'message': 'Unauthorized request.'}
      }),
      headers: {'content-type': 'application/json'}));
}

Future<shelf.Response> _badRequest(String message) {
  return new Future.value(new shelf.Response(400,
      body: JSON.encode({
        'error': {'message': message}
      }),
      headers: {'content-type': 'application/json'}));
}

Future<shelf.Response> _binaryJsonResponse(List<int> d, {int status: 200}) {
  return new Future.sync(() {
    return new shelf.Response(status,
        body: new Stream.fromIterable([d]),
        headers: {'content-type': 'application/json'});
  });
}

// TODO: avoid
Future<shelf.Response> _jsonResponse(Map json, {int status: 200}) {
  return new Future.sync(() {
    return new shelf.Response(status,
        body: JSON.encode(json), headers: {'content-type': 'application/json'});
  });
}

// Download urls.

Uri _downloadUrl(Uri url, String package, String version) {
  var encode = Uri.encodeComponent;
  return url.resolve(
      '/packages/${encode(package)}/versions/${encode(version)}.tar.gz');
}

// Upload async urls.

Uri _finishUploadAsyncUrl(Uri url) {
  return url.resolve('/api/packages/versions/newUploadFinish');
}

// Upload custom urls.

Uri _uploadSimpleUrl(Uri url) {
  return url.resolve('/api/packages/versions/newUpload');
}

Uri _finishUploadSimpleUrl(Uri url, {String error}) {
  var postfix = error == null ? '' : '?error=${Uri.encodeComponent(error)}';
  return url.resolve('/api/packages/versions/newUploadFinish$postfix');
}

class _PoorMansResourceDI {
  final PackageRepository repository;
  final PackageCache cache;

  _PoorMansResourceDI(this.repository, {this.cache});

  PubApiResource createPubApiResource() =>
      new PubApiResource(repository, createPackagesResource(), cache: cache);

  PackagesResource createPackagesResource() => new PackagesResource(
      repository, createVersionsResource(), createUpLoadersResource(),
      cache: cache);

  VersionsResource createVersionsResource() =>
      new VersionsResource(repository, cache: cache);

  UpLoadersResource createUpLoadersResource() =>
      new UpLoadersResource(repository, cache: cache);
}

@deprecated // just here for test compatibility
class ShelfPubServer {
  final PubApiResource _pubApiResource;

  ShelfPubServer(PackageRepository repository, {PackageCache cache})
      : this._pubApiResource = createPubApiResource(repository, cache: cache);

  Future<shelf.Response> requestHandler(shelf.Request request) {
    final r = router()..addAll(_pubApiResource);

    return r.handler(request);
  }
}

PubApiResource createPubApiResource(PackageRepository repository,
        {PackageCache cache}) =>
    new _PoorMansResourceDI(repository, cache: cache).createPubApiResource();
