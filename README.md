# OdinSQL

Mobile-first SQL Server client with Flutter. Direct TCP connection to SQL Server, using its existing IP and port, no API middleware.

## Version 0.1 scope
- Save multiple server profiles with custom name, color, photo, host, port and username.
- Keep passwords separately in device secure storage.
- Open independent connections to multiple SQL Server databases.
- Browse database names, tables and columns (subject to SQL permissions).
- Multiple SQL editor tabs, arbitrary T-SQL, and tabular query results.
- Confirm potentially destructive SQL before running.

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

## Roadmap (not implemented in v0.1)
SSMS-like Object Explorer for views, stored procedures, functions, indexes and jobs; schema editing; query autocomplete; export, advanced result editing, execution plans, history and backup/restore.

## Files
- lib/models/server_profile.dart — saved connection metadata
- lib/data/server_repository.dart — profile storage and password vault
- lib/data/sql_manager.dart — independent database sessions
- lib/main.dart — mobile app
