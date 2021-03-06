// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:gcloud/db.dart';
import 'package:test/test.dart';

import 'package:pub_dev/account/models.dart';
import 'package:pub_dev/package/models.dart';
import 'package:pub_dev/publisher/models.dart';
import 'package:pub_dev/shared/user_merger.dart';

import 'test_models.dart';
import 'test_services.dart';

void main() {
  Future<void> _updateUsers() async {
    await dbService.withTransaction((tx) async {
      final users = await tx.lookup<User>([hansUser.key, joeUser.key]);
      users.forEach((u) => u.oauthUserId = 'oauth-1');
      tx.queueMutations(inserts: users);
      tx.queueMutations(inserts: [
        OAuthUserID()
          ..id = 'oauth-1'
          ..userIdKey =
              Key.emptyKey(Partition(null)).append(User, id: joeUser.userId)
      ]);
      await tx.commit();
    });
  }

  Future<void> _corruptAndFix() async {
    await _updateUsers();
    final merger = UserMerger(
      db: dbService,
      concurrency: 2,
      omitEmailCheck: true,
    );
    await merger.fixAll();
  }

  testWithServices('packages and versions', () async {
    final control = generateBundle(
      'control',
      ['1.0.0'],
      uploaders: [adminUser],
    );
    await dbService.commit(inserts: [
      control.package,
      ...control.versions,
      ...control.infos,
      ...control.assets,
    ]);

    await _corruptAndFix();

    final pkgList = await dbService.lookup<Package>([
      foobarPkgKey,
      control.packageKey,
    ]);
    expect(pkgList[0].uploaders, [joeUser.userId]);
    expect(pkgList[1].uploaders, [adminUser.userId]);

    final pvList = await dbService.lookup<PackageVersion>([
      foobarStablePVKey,
      control.versions.single.key,
    ]);
    expect(pvList[0].uploader, joeUser.userId);
    expect(pvList[1].uploader, adminUser.userId);
  });

  testWithServices('session', () async {
    await dbService.commit(inserts: [
      UserSession()
        ..id = 'target'
        ..userId = hansUser.userId
        ..email = 'target@domain.com'
        ..created = DateTime.now()
        ..expires = DateTime.now(),
      UserSession()
        ..id = 'control'
        ..userId = adminUser.userId
        ..email = 'control@domain.com'
        ..created = DateTime.now()
        ..expires = DateTime.now(),
    ]);

    await _corruptAndFix();

    final list = await dbService.lookup<UserSession>([
      dbService.emptyKey.append(UserSession, id: 'target'),
      dbService.emptyKey.append(UserSession, id: 'control'),
    ]);
    expect(list[0].userId, joeUser.userId);
    expect(list[1].userId, adminUser.userId);
  });

  testWithServices('new consent', () async {
    final target1 = Consent.init(
        email: hansUser.email,
        kind: 'k1',
        args: ['1'],
        fromUserId: adminUser.userId);
    final target2 = Consent.init(
        email: adminUser.email,
        kind: 'k2',
        args: ['2'],
        fromUserId: hansUser.userId);
    final control = Consent.init(
        email: adminUser.email,
        kind: 'k3',
        args: ['3'],
        fromUserId: adminUser.userId);
    await dbService.commit(inserts: [target1, target2, control]);

    await _corruptAndFix();

    final list = await dbService.query<Consent>().run().toList();
    final updated1 = list.firstWhere((c) => c.id == target1.id);
    final updated2 = list.firstWhere((c) => c.id == target2.id);
    final updated3 = list.firstWhere((c) => c.id == control.id);

    expect(updated1.fromUserId, adminUser.userId);
    expect(updated2.fromUserId, joeUser.userId);
    expect(updated3.fromUserId, adminUser.userId);
  });

  testWithServices('publisher membership', () async {
    final control = publisherMember(adminUser.userId, 'admin');
    await dbService.commit(inserts: [control]);
    final before = await dbService.query<PublisherMember>().run().toList();
    expect(before.map((m) => m.userId).toList()..sort(), [
      adminUser.userId,
      hansUser.userId,
    ]);

    await _corruptAndFix();

    final after = await dbService.query<PublisherMember>().run().toList();
    expect(after.map((m) => m.userId).toList()..sort(), [
      adminUser.userId,
      joeUser.userId,
    ]);
  });
}
