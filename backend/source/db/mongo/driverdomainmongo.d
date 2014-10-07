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
