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
module db.mongo.driverusermongo;

version(MongoDriver)
{
import db.dbinterface.driveruserinterface;
import db.mongo.mongo;
import db.user: User;
import vibe.data.bson;
import vibe.db.mongo.mongo;

final class DriverUserMongo : DriverUserInterface
{
    private User getObjectFromField(in string fieldName, in string fieldValue)
    {
        immutable userResult = collection("user").findOne([fieldName: fieldValue]);
        return userResult.isNull ? null : userDocToObject(userResult);
    }


    private User userDocToObject(const ref Bson userDoc)
    {
        auto ret = new User();
        if (userDoc.isNull)
            return ret;

        ret.id = bsonStr(userDoc._id);
        ret.loginName = bsonStr(userDoc.loginName);
        ret.addresses = bsonStrArray(userDoc.addresses);
        ret.admin = bsonBool(userDoc.admin);
        ret.loginHash = bsonStr(userDoc.loginHash);
        ret.name = bsonStr(userDoc.name);
        ret.surname = bsonStr(userDoc.surname);
        return ret;
    }

//override: // buggy compiled doesnt detect the override
    User get(in string id)
    {
        return getObjectFromField("_id", id);
    }


    User getFromLoginName(in string login)
    {
        return getObjectFromField("loginName", login);
    }

    string getIdFromLoginName(in string login)
    {
        immutable userResult = collection("user").findOne(["loginName": login]);
        return userResult.isNull? "": bsonStrSafe(userResult._id);
    }


    User getFromAddress(in string address)
    {
        immutable userResult = collection("user").findOne(
                parseJsonString(`{"addresses": {"$in": [` ~ Json(address).toString ~ `]}}`)
        );
        return userResult.isNull ? null : userDocToObject(userResult);
    }
}
} // end version(MongoDriver)
