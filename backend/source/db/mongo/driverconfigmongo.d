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
module db.mongo.driverconfigmongo;

version(MongoDriver)
{
import db.config: RetrieverConfig;
import db.dbinterface.driverconfiginterface;
import db.mongo.mongo;
import std.conv;
import std.path;
import std.string;
import vibe.core.log;

final class DriverConfigMongo : DriverConfigInterface
{
override:

    RetrieverConfig getConfig()
    {
        RetrieverConfig config;

        immutable dbConfig = collection("settings").findOne(["module": "retriever"]);
        if (dbConfig.isNull)
        {
            auto err = "Could not retrieve config database, collection:settings,"~
                       " module=retriever";
            logError(err);
            throw new Exception(err);
        }

        void checkNotNull(in string[] keys)
        {
            string[] missingKeys = [];
            foreach(key; keys)
            {
                if (dbConfig[key].isNull)
                    missingKeys ~= key;
            }

            if (missingKeys.length)
            {
                auto err = "Missing keys in retriever DB config collection: " ~
                                     to!string(missingKeys);
                logError(err);
                throw new Exception(err);
            }
        }

        checkNotNull(["mainDir", "apiDomain", "smtpServer", "smtpUser", "smtpPass",
                "smtpEncryption", "smtpPort", "rawEmailStore", "attachmentStore", "salt",
                "incomingMessageLimit", "storeTextIndex", "bodyPeekLength",
                "URLAttachmentPath", "URLStaticPath"]);

        config.mainDir              = bsonStr(dbConfig.mainDir);
        config.apiDomain            = bsonStr(dbConfig.apiDomain);
        config.smtpServer           = bsonStr(dbConfig.smtpServer);
        config.smtpUser             = bsonStr(dbConfig.smtpUser);
        config.smtpPass             = bsonStr(dbConfig.smtpPass);
        config.smtpEncryption       = to!uint(bsonNumber(dbConfig.smtpEncryption));
        config.smtpPort             = to!ulong(bsonNumber(dbConfig.smtpPort));
        config.salt                 = bsonStr(dbConfig.salt);
        auto dbPath                 = bsonStr(dbConfig.rawEmailStore);
        // If the db path starts with '/' interpret it as absolute
        config.rawEmailStore        = dbPath.startsWith(dirSeparator)?
                                                               dbPath:
                                                               buildPath(config.mainDir,
                                                                         dbPath);
        auto attachPath             = bsonStr(dbConfig.attachmentStore);
        config.attachmentStore      = attachPath.startsWith(dirSeparator)?
                                                                   attachPath:
                                                                   buildPath(config.mainDir,
                                                                             attachPath);
        config.incomingMessageLimit = to!ulong(bsonNumber(dbConfig.incomingMessageLimit));
        config.storeTextIndex       = bsonBool(dbConfig.storeTextIndex);
        config.bodyPeekLength       = to!uint(bsonNumber(dbConfig.bodyPeekLength));
        config.URLAttachmentPath    = bsonStr(dbConfig.URLAttachmentPath);
        config.URLStaticPath        = bsonStr(dbConfig.URLStaticPath);
        return config;
    }

    void insertTestSettings()
    {
        import vibe.data.json;

        collection("settings").remove();
        auto homeDir = expandTilde("~/wodri");
        string settingsJsonStr = format(`
        {
                "_id"                  : "5399793904ac3d27431d0669",
                "mainDir"              : "%s",
                "apiDomain"            : "juanjux.mooo.com",
                "salt"                 : "someSalt",
                "attachmentStore"      : "backend/test/attachments",
                "incomingMessageLimit" : 15728640,
                "storeTextIndex"       : true,
                "module"               : "retriever",
                "rawEmailStore"        : "backend/test/rawemails",
                "smtpEncryption"       : 1,
                "smtpUser"             : "someuser",
                "smtpPass"             : "somepass",
                "smtpPort"             : 25,
                "smtpServer"           : "localhost",
                "bodyPeekLength"       : 100,
                "URLAttachmentPath"    : "attachment",
                "URLStaticPath"        : "public",
        }`, homeDir);
        collection("settings").insert(parseJsonString(settingsJsonStr));
    }
}
} // end MongoDriver
