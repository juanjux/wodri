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
