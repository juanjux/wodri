module db.dbinterface.driverdomaininterface;

import std.typecons;

interface DriverDomainInterface
{
    Flag!"HasDefaultUser" hasDefaultUser(in string domainName);
}
