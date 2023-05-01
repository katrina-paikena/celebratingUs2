import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tekartik_app_flutter_sqflite/sqflite.dart';
import 'package:tekartik_common_utils/common_utils_import.dart';

import '../model/model.dart';
import '../model/model_constant.dart';

//for CSV ?
import 'dart:async';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import '../model/nameday_constant.dart';

DbNote snapshotToNote(Map<String, Object?> snapshot) {
  return DbNote()..fromMap(snapshot);
}

class DbNotes extends ListBase<DbNote> {
  final List<Map<String, Object?>> list;
  late List<DbNote?> _cacheNotes;

  DbNotes(this.list) {
    _cacheNotes = List.generate(list.length, (index) => null);
  }

  @override
  DbNote operator [](int index) {
    return _cacheNotes[index] ??= snapshotToNote(list[index]);
  }

  @override
  int get length => list.length;

  @override
  void operator []=(int index, DbNote? value) => throw 'read-only';

  @override
  set length(int newLength) => throw 'read-only';
}

class DbNoteProvider {
  final lock = Lock(reentrant: true);
  final DatabaseFactory dbFactory;
  final _updateTriggerController = StreamController<bool>.broadcast();
  Database? db;

  DbNoteProvider(this.dbFactory);

  Future openPath(String path) async {
    db = await dbFactory.openDatabase(path,
        options: OpenDatabaseOptions(
            version: kVersion1,
            onCreate: (db, version) async {
              await _createDb(db);
            },
            onUpgrade: (db, oldVersion, newVersion) async {
              if (oldVersion < kVersion1) {
                await _createDb(db);
              }
            }));
  }

  void _triggerUpdate() {
    _updateTriggerController.sink.add(true);
  }

  Future<Database?> get ready async => db ??= await lock.synchronized(() async {
        if (db == null) {
          await open();
        }
        return db;
      });


//GET CELEBRATION FROM ID
  Future<DbNote?> getNote(int? id) async {
    var list = (await db!.query(tableNotes,
        columns: [
          columnId,
          columnTitle,
          columnContent,
          columnUpdated,
          columnDate,
          columnType
        ],
        where: '$columnId = ?',
        whereArgs: <Object?>[id]));
    if (list.isNotEmpty) {
      return DbNote()..fromMap(list.first);
    }
    return null;
  }

//CREATE TABLES
  Future _createDb(Database db) async {
    await db.execute('DROP TABLE If EXISTS $tableNotes');
    await db.execute(
        'CREATE TABLE $tableNotes($columnId INTEGER PRIMARY KEY, $columnTitle TEXT, $columnContent TEXT, $columnUpdated INTEGER, $columnDate INTEGER, $columnType TEXT)');
    await db
        .execute('CREATE INDEX NotesUpdated ON $tableNotes ($columnUpdated)');
    await _createNamedayTable(db);
    //SAMPLE DATA
    await _saveNote(
        db,
        DbNote()
          ..title.v = 'Inese'
          ..content.v = 'grāmata par ceļojumiem'
          ..date.v = 1
          ..specialday.v = 1687622400000
          ..type.v = 'nameday');
    await _saveNote(
        db,
        DbNote()
          ..title.v = 'Sintija'
          ..content.v = 'biļetes uz koncertu'
          ..date.v = 2
          ..specialday.v = 1690310400000
          ..type.v = 'nameday');
    _triggerUpdate();
  }

  Future open() async {
    await openPath(await fixPath(dbName));
  }

  Future<String> fixPath(String path) async => path;

  /// ADD or UPDATE CELEBRATION
  Future _saveNote(DatabaseExecutor? db, DbNote updatedNote) async {
    if (updatedNote.id.v != null) {
      await db!.update(tableNotes, updatedNote.toMap(),
          where: '$columnId = ?', whereArgs: <Object?>[updatedNote.id.v]);
    } else {
      updatedNote.id.v = await db!.insert(tableNotes, updatedNote.toMap());
    }
  }

  Future saveNote(DbNote updatedNote) async {
    await _saveNote(db, updatedNote);
    _triggerUpdate();
  }

  Future<void> deleteNote(int? id) async {
    await db!
        .delete(tableNotes, where: '$columnId = ?', whereArgs: <Object?>[id]);
    _triggerUpdate();
  }

  var notesTransformer =
      StreamTransformer<List<Map<String, Object?>>, List<DbNote>>.fromHandlers(
          handleData: (snapshotList, sink) {
    sink.add(DbNotes(snapshotList));
  });

  var noteTransformer =
      StreamTransformer<Map<String, Object?>, DbNote?>.fromHandlers(
          handleData: (snapshot, sink) {
    sink.add(snapshotToNote(snapshot));
  });

  /// Listen for changes on any note
  Stream<List<DbNote?>> onNotes() {
    late StreamController<DbNotes> ctlr;
    StreamSubscription? triggerSubscription;

    Future<void> sendUpdate() async {
      var notes = await getListNotes();
      if (!ctlr.isClosed) {
        ctlr.add(notes);
      }
    }

    ctlr = StreamController<DbNotes>(onListen: () {
      sendUpdate();

      /// Listen for trigger
      triggerSubscription = _updateTriggerController.stream.listen((_) {
        sendUpdate();
      });
    }, onCancel: () {
      triggerSubscription?.cancel();
    });
    return ctlr.stream;
  }

  /// Listed for changes on a given note
  Stream<DbNote?> onNote(int? id) {
    late StreamController<DbNote?> ctlr;
    StreamSubscription? triggerSubscription;

    Future<void> sendUpdate() async {
      var note = await getNote(id);
      if (!ctlr.isClosed) {
        ctlr.add(note);
      }
    }

    ctlr = StreamController<DbNote?>(onListen: () {
      sendUpdate();

      /// Listen for trigger
      triggerSubscription = _updateTriggerController.stream.listen((_) {
        sendUpdate();
      });
    }, onCancel: () {
      triggerSubscription?.cancel();
    });
    return ctlr.stream;
  }

  /// GET ALL SAVED CELEBRATIONS
  Future<DbNotes> getListNotes(
      {int? offset, int? limit, bool? descending}) async {
    // devPrint('fetching $offset $limit');
    var list = (await db!.query(tableNotes,
        columns: [columnId, columnTitle, columnContent, columnDate, columnType],
        orderBy: '$columnDate ${(descending ?? true) ? 'ASC' : 'DESC'}',
        limit: limit,
        offset: offset));
    return DbNotes(list);
  }
 // GET CELEBRATIONS FOR DATE SELECTED
  //  Future<DbNotes> getEventsForDay(DateTime date) async {
  //   var list = (await db!.query(tableNotes,
  //       columns: [columnId, columnTitle, columnContent, columnDate, columnType],
  //       where: '$columnDate = ?',
  //       whereArgs: [date],
  //       //orderBy: '$columnDate ${(descending ?? true) ? 'ASC' : 'DESC'}',
  //       //limit: limit,
  //       //offset: offset
  //       ));
  //   return DbNotes(list);
  // }
// Future<List<DbNote>> getEventsForDay(DateTime selectedDate) async {
//   final startOfSelectedDay =
//       DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
//   final endOfSelectedDay = startOfSelectedDay.add(Duration(days: 1));

//   final results = await db!.query(
//     tableNotes,
//     where: '$columnDate >= ? AND $columnDate < ?',
//     whereArgs: [
//       startOfSelectedDay.millisecondsSinceEpoch,
//       endOfSelectedDay.millisecondsSinceEpoch
//     ],
//   );

//   return results.map((snapshot) => snapshotToNote(snapshot)).toList();
// }
// Future<List<DbNote>?> getEventsForDay(DateTime selectedDate) async {
//   final startOfSelectedDay =
//       DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
//   final endOfSelectedDay = startOfSelectedDay.add(Duration(days: 1));

//   final results = await db!.query(
//     tableNotes,
//     where: '$columnDate >= ? AND $columnDate < ?',
//     whereArgs: [
//       startOfSelectedDay.millisecondsSinceEpoch,
//       endOfSelectedDay.millisecondsSinceEpoch
//     ],
//   );

//   if (results.isEmpty) {
//     return null;
//   }

//   return results.map((snapshot) => snapshotToNote(snapshot)).toList();
// }
Future<List<DbNote>> getEventsForDay(DateTime selectedDate) async {
  final startOfSelectedDay =
      DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
  final endOfSelectedDay = startOfSelectedDay.add(Duration(days: 1));

  final results = await db!.query(
    tableNotes,
    where: '$columnDate >= ? AND $columnDate < ?',
    whereArgs: [
      startOfSelectedDay.millisecondsSinceEpoch,
      endOfSelectedDay.millisecondsSinceEpoch
    ],
  );

  return results.map((snapshot) => snapshotToNote(snapshot)).toList();
}


  Future clearAllNotes() async {
    await db!.delete(tableNotes);
    _triggerUpdate();
  }

  Future close() async {
    await db!.close();
  }

  Future deleteDb() async {
    await dbFactory.deleteDatabase(await fixPath(dbName));
  }


//parse CSV and write to table
  Future<void> _createNamedayTable(Database db) async {
    await db.execute('DROP TABLE IF EXISTS $tableNameday');
    await db.execute(
        'CREATE TABLE $tableNameday($colId INTEGER PRIMARY KEY, $colDate TEXT, $colName TEXT)');
    var csvString = await rootBundle.loadString('assets/varda_dienas.csv');
    // print("namedays csv string: $csvString");
    // Clean up nameday csv - remove any quotes and empty space
    csvString = csvString.replaceAll(RegExp('"'), '');
    csvString = csvString.replaceAll(RegExp(' '), '');

    final lines = csvString.split('\n');
    final namedays = <Nameday>[];
    for (final line in lines) {
      final fields = line.split(',');
      if (fields.length == 2) {
        final date = fields[0];
        final name = fields[1];
        namedays.add(Nameday(date: date, name: name));
      } else {
        // If there are more than 1 nameday for the date, we have to add them all
        for (final field in fields) {
          if (field != fields[0]) {
            namedays.add(Nameday(date: fields[0], name: field));
          }
        }
      }
    }

    for (final nameday in namedays) {
      final insertedId = await db.rawInsert(
          'INSERT INTO $tableNameday($colDate, $colName) VALUES (?, ?)',
          [nameday.date, nameday.name]);
      //print("inserted value ${nameday.date}, ${nameday.name} into nameday database, id = $insertedId");
    }
    print("inserted ${namedays.length} lines into nameday database");
  }

//GET nameday for date selected
Future<String?> getNameday(String date) async {
  var result = await db?.query(tableNameday,
      columns: [colName],
      where: '$colDate = ?',
      whereArgs: [date]);

  if (result != null && result.isNotEmpty) {
    final List<String> resultList = [];
    for (final line in result) {
      resultList.add(line[colName] as String);
    }

    return resultList.join(', ');
    //return result.first[colName] as String?;
  } else {
    return null;
  }
}


  

  
}
