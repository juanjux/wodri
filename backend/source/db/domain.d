module db.domain;

import std.typecons;
import db.dbinterface.driverdomaininterface;
version(MongoDriver)
{
    import vibe.db.mongo.mongo;
    import db.mongo.mongo;
    import db.mongo.driverdomainmongo;
}

final class Domain
{
    private static DriverDomainInterface dbDriver = null;

    static this()
    {
        version(MongoDriver)
            dbDriver = new DriverDomainMongo();
    }

    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================
    static Flag!"HasDefaultUser" hasDefaultUser(in string domainName)
    {
        return dbDriver.hasDefaultUser(domainName);
    }
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


version(db_test)
version(db_usetestdb)
{
    import std.stdio;
    import db.test_support;

    unittest // hasDefaultUser
    {
        writeln("Testing DriverDomainMongo.hasDefaultUser");
        recreateTestDb();
        assert(Domain.hasDefaultUser("testdatabase.com"), "Domain.hasDefaultUser1");
        assert(!Domain.hasDefaultUser("anotherdomain.com"), "Domain.hasDefaultUser2");
    }
}
