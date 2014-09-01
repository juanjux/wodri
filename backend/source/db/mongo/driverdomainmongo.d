module db.mongo.driverdomainmongo;


version(MongoDriver)
{
import db.dbinterface.driverdomaininterface;
import db.mongo.mongo;
import std.typecons;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import db.domain: Domain;

final class DriverDomainMongo : DriverDomainInterface
{
override:
    Flag!"HasDefaultUser" hasDefaultUser(in string domainName)
    {
        immutable domain = collection("domain").findOne(
                ["name": domainName], ["defaultUser": 1], QueryFlags.None
        );
        if (!domain.isNull &&
            !domain.defaultUser.isNull &&
            bsonStr(domain.defaultUser).length)
            return Yes.HasDefaultUser;
        return No.HasDefaultUser;
    }
}
} // end version(MongoDriver)


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
