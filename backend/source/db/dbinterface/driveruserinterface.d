module db.dbinterface.driveruserinterface;

import std.typecons;
import db.user: User;

interface DriverUserInterface
{
    User get(in string id);

    User getFromLoginName(in string login);

    User getFromAddress(in string address);

    string getIdFromLoginName(in string login);
}
