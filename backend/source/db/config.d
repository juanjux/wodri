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
module db.config;

import db.dbinterface.driverconfiginterface;
import std.path;
import std.exception: enforce;

version(MongoDriver)
{
    import db.mongo.mongo;
    import db.mongo.driverconfigmongo;
}

version(db_usetestdb)     version = anytestdb;
version(db_usebigdb)      version = anytestdb;
version(db_insertalltest) version = anytestdb;
version(db_insertalltest) version = db_usebigdb;
version(search_test)      version = db_usebigdb;

struct RetrieverConfig
{
    string mainDir;
    string apiDomain;
    string rawEmailStore;
    string attachmentStore;
    string salt;
    ulong  incomingMessageLimit;
    bool   storeTextIndex;
    string smtpServer;
    uint   smtpEncryption;
    ulong  smtpPort;
    string smtpUser;
    string smtpPass;
    uint   bodyPeekLength;
    string URLAttachmentPath;
    string URLStaticPath;

    @property string absAttachmentStore() const
    nothrow
    {
        return buildPath(this.mainDir, this.attachmentStore);
    }

    @property string absRawEmailStore() const
    nothrow
    {
        return buildPath(this.mainDir, this.rawEmailStore);
    }
}

private shared immutable RetrieverConfig g_retrieverConfig;
private DriverConfigInterface g_driverInterface;

// Read config from the DB into g_config
shared static this()
{
    version(MongoDriver)
    {
        g_driverInterface = new DriverConfigMongo();
    }
    enforce(g_driverInterface !is null, "Configure a DB backend");

    version(anytestdb)
    {
        g_driverInterface.insertTestSettings();
    }

    g_retrieverConfig = g_driverInterface.getConfig();
}

ref immutable(RetrieverConfig) getConfig() { return g_retrieverConfig; }
