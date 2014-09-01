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
