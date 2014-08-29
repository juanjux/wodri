module db.db_util;

static this()
{
    // check that no more than one DB driver is selected
    version(MongoDriver)
    {
        version(SqliteDriver)
            static assert(0, "You must select only one DB driver");
        version(PostgreSQLDriver)
            static assert(0, "You must select only one DB driver");
    }

    version(SqliteDriver)
    {
        version(PostgreSQLDriver)
            static assert(0, "You must select only one DB driver");
    }
}

