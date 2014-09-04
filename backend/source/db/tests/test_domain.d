module db.tests.test_domain;


version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.domain;
    import db.test_support;

    version(MongoDriver)
    {
        unittest // hasDefaultUser
        {
            writeln("Testing DriverDomainMongo.hasDefaultUser");
            recreateTestDb();
            assert(Domain.hasDefaultUser("testdatabase.com"), "Domain.hasDefaultUser1");
            assert(!Domain.hasDefaultUser("anotherdomain.com"), "Domain.hasDefaultUser2");
        }
    }
}
