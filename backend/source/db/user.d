/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/
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
