-- The database users of the driver servers, one for each login method of
-- test/docker/driver_pg_hba.conf. The image runs this file once, when it
-- makes the database dream_test. The user dream comes from POSTGRES_USER.
-- All passwords are 'dream'.
CREATE ROLE dream_trust LOGIN;
CREATE ROLE dream_cleartext LOGIN PASSWORD 'dream';
CREATE ROLE dream_tls LOGIN PASSWORD 'dream';

-- The md5 method falls back to SCRAM when the server keeps the password as
-- a SCRAM secret, so this password is kept as MD5. PostgreSQL 18 and later
-- warn that MD5 passwords are deprecated.
SET password_encryption = 'md5';
CREATE ROLE dream_md5 LOGIN PASSWORD 'dream';
RESET password_encryption;

-- The connection tests change this user's password while a connection is
-- logged in, so a reconnect fails, and set it back. No other test uses it.
CREATE ROLE dream_reconnect LOGIN PASSWORD 'dream';
