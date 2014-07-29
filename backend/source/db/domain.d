module db.domain;

import std.typecons;
import vibe.db.mongo.mongo;
import db.mongo;

class Domain
{
    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================
    static Flag!"HasDefaultUser" hasDefaultUser(string domainName)
    {
        auto domain = collection("domain").findOne(["name": domainName],
                                                   ["defaultUser": 1],
                                                   QueryFlags.None);
        if (!domain.isNull &&
            !domain.defaultUser.isNull &&
            bsonStr(domain.defaultUser).length)
            return Yes.HasDefaultUser;
        return No.HasDefaultUser;
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
        writeln("Testing Domain.hasDefaultUser");
        recreateTestDb();
        assert(Domain.hasDefaultUser("testdatabase.com"), "Domain.hasDefaultUser1");
        assert(!Domain.hasDefaultUser("anotherdomain.com"), "Domain.hasDefaultUser2");
    }
}
