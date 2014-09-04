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
