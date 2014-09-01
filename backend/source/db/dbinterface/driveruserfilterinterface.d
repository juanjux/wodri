module db.dbinterface.driveruserfilterinterface;

import db.userfilter: UserFilter;

interface DriverUserfilterInterface
{
    UserFilter[] getByAddress(in string address);
}
