module db.user;

import std.array;
version(MongoDriver)
{
    import db.dbinterface.driveruserinterface;
    import db.mongo.driverusermongo;
}

final class User
{
    string id;
    string loginName;
    string[] addresses;
    bool admin;
    string loginHash;
    string name;
    string surname;

    private static DriverUserInterface dbDriver = null;

    static this()
    {
        version(MongoDriver)
            dbDriver = new DriverUserMongo();
    }

    static bool addressIsLocal(in string address)
    {
        import db.domain: Domain;

        if (!address.length)
            return false;
        if (Domain.hasDefaultUser(address.split("@")[1]))
            return true;
        return (getFromAddress(address) !is null);
    }

    // ==========================================================
    // Proxies for the dbDriver functions used outside this class
    // ==========================================================
    static User get(in string id) { return dbDriver.get(id); }


    static User getFromLoginName(in string login)
    {
        return dbDriver.getFromLoginName(login);
    }

    static string getIdFromLoginName(in string login)
    {
        return dbDriver.getIdFromLoginName(login);
    }


    static User getFromAddress(in string address)
    {
        return dbDriver.getFromAddress(address);
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

    unittest // User.addressIsLocal
    {
        writeln("Testing User.addressIsLocal");
        recreateTestDb();
        assert(User.addressIsLocal("testuser@testdatabase.com"));
        assert(User.addressIsLocal("random@testdatabase.com")); // has default user
        assert(User.addressIsLocal("anotherUser@testdatabase.com"));
        assert(User.addressIsLocal("anotherUser@anotherdomain.com"));
        assert(!User.addressIsLocal("random@anotherdomain.com"));
    }
}
