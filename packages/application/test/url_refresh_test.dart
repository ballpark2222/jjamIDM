import 'package:freedm_application/freedm_application.dart';
import 'package:freedm_core_domain/freedm_core_domain.dart';
import 'package:test/test.dart';

void main() {
  const v = SameFileValidator();

  DownloadSource src({
    String? etag,
    String? lm,
    int? len,
    String? ct,
  }) =>
      DownloadSource(
        initialUrl: 'http://x/f',
        etag: etag,
        lastModified: lm,
        contentLength: len,
        contentType: ct,
      );

  RefreshedSource fresh({
    String? etag,
    String? lm,
    int? len,
    String? ct,
  }) =>
      RefreshedSource(
        url: 'http://x/f?new-token',
        etag: etag,
        lastModified: lm,
        contentLength: len,
        contentType: ct,
      );

  test('equal etags match; weak prefix tolerated', () {
    expect(v.validate(src(etag: '"abc"'), fresh(etag: '"abc"')),
        SameFileVerdict.match);
    expect(v.validate(src(etag: 'W/"abc"'), fresh(etag: '"abc"')),
        SameFileVerdict.match);
  });

  test('different etags conflict', () {
    expect(v.validate(src(etag: '"a"'), fresh(etag: '"b"')),
        SameFileVerdict.conflict);
  });

  test('length mismatch conflicts; equal length is a match signal',
      () {
    expect(v.validate(src(len: 100), fresh(len: 200)),
        SameFileVerdict.conflict);
    expect(v.validate(src(len: 100), fresh(len: 100)),
        SameFileVerdict.match);
  });

  test('lastModified mismatch conflicts', () {
    expect(
        v.validate(src(len: 5, lm: 'Mon'), fresh(len: 5, lm: 'Tue')),
        SameFileVerdict.conflict);
  });

  test('content-type mismatch conflicts', () {
    expect(
        v.validate(src(ct: 'video/mp4'), fresh(ct: 'text/html')),
        SameFileVerdict.conflict);
  });

  test('no comparable metadata → indeterminate (allowed)', () {
    expect(v.validate(src(), fresh()), SameFileVerdict.indeterminate);
    expect(
        v.validate(src(etag: '"a"'), fresh()), // fresh lacks etag
        SameFileVerdict.indeterminate);
  });
}
