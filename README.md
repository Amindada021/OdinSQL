# OdinSQL

Mobile-first SQL Server client with Flutter. Direct TCP connection to SQL Server, using its existing IP and port, no API middleware.

## Studio features
- Persisted dark, light and system themes; Persian/English UI and adaptive landscape panes.
- Multiple servers with names, colors, photos, favorites, search, connection probes and server information.
- Independent persistent query sessions per tab, direct TCP/IP and SQL Server permissions.
- Object Explorer: databases, tables, views, stored procedures, functions, columns, keys and indexes.
- SELECT TOP 100/1000, INSERT/UPDATE/DELETE templates and module definition scripts.
- T-SQL highlighting, line numbers, keyword/table-name completion, whitespace formatting and undo/redo.
- Execute selected text or the entire editor, choose a database, cancel queries and configure timeout.
- Multiple result sets, SQL Server messages, lazy grid rows, full-cell inspection and copy.
- CSV and JSON export through Android's save-file picker. JSON retains ordinal columns, duplicate labels and NULLs.
- Encrypted query history (latest 100 executions), named saved queries and automatic open-tab recovery.
- Confirmation before statements that may change data or schema. No SQL verb allowlist and no automatic write retry.

## Current limits
Results are buffered with a ceiling of 10,000 rows and 32 MiB. Exceeding a driver limit reports an error; it is not server-side pagination. Use a smaller query to retrieve a bounded result. Writes may already have run when a limit or connection error is reported; inspect database state before repeating them.

Completion is keyword/table based, not a semantic IntelliSense engine. Table scripts are DML templates; full CREATE TABLE/constraint/index DDL generation, GO batch separators, execution plans, grid editing and streaming exports remain future work. Format preserves identifier casing, literals and comments.

Recovered tabs do not connect or execute automatically. Result data and live transactions are not persisted across app restarts. Explicit transactions and temporary tables belong to their tab session; closing a tab or disconnecting closes that session. The database selector follows raw USE statements.

No build, analysis, tests or APK execution were performed for this development pass. Commits use [skip ci] so the existing push workflow does not build them automatically.

## Setup
Requires Flutter 3.38+ and Dart 3.10+, Android API 24+.

On a workstation with Flutter installed, run from the repository root:

    flutter create . --platforms=android --project-name=odin_sql --org=com.odin
    flutter pub get
    flutter run

Keep the existing lib/main.dart when Flutter generates boilerplate. Flutter creates the standard android/ folder. Add android.permission.INTERNET to AndroidManifest.xml if missing.

## Connection
Enter the same host/IP, configured TCP port, SQL login and password used in SSMS. SQL Server TCP must be reachable from the phone. Named instances require the instance's actual TCP port.

## Security
Do not open SQL Server to the entire public internet. Restrict IP/network or use an existing VPN without changing the SQL Server port. SQL credentials are not stored in plaintext preferences, logs or this repository. v0.1 does not configure a trusted CA for verified encrypted sessions; add proper TLS trust before using hostile networks. Query permissions come directly from the selected SQL login.

## Files
- lib/models/server_profile.dart — saved connection metadata
- lib/data/server_repository.dart — serialized profile storage and password vault
- lib/data/sql_manager.dart — direct sessions, catalog metadata and script templates
- lib/data/query_repository.dart — encrypted queries and workspace recovery
- lib/ui/ — appearance, Object Explorer, SQL editor, result grid and query history
- lib/main.dart — application shell and workflows
