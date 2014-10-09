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
module db.tests.test_email;

version(db_test)
version(db_usetestdb)
{
    import db.conversation;
    import db.email;
    import db.test_support;
    import db.user;
    import retriever.incomingemail;
    import std.algorithm;
    import std.digest.digest;
    import std.digest.md;
    import std.file;
    import std.range;
    import std.stdio;
    import std.string;
    import std.typecons;
    import webbackend.apiemail;

    unittest  // this(ApiEmail)
    {
        writeln("Testing Email.this(ApiEmail)");
        auto user         = User.getFromAddress("anotherUser@testdatabase.com");
        auto apiEmail     = new ApiEmail;
        apiEmail.from     = "anotherUser@testdatabase.com";
        apiEmail.to       = "juanjux@gmail.com";
        apiEmail.subject  = "draft subject 1";
        apiEmail.isoDate  = "2014-08-20T15:47:06Z";
        apiEmail.date     = "Wed, 20 Aug 2014 15:47:06 +02:00";
        apiEmail.deleted  = false;
        apiEmail.draft    = true;
        apiEmail.bodyHtml = "<strong>I can do html like the cool boys!</strong>";

        // Test1: New draft, no reply
        auto dbEmail   = new Email(apiEmail, "");
        dbEmail.userId = user.id;
        dbEmail.store();
        assert(dbEmail.id.length);
        assert(dbEmail.messageId.endsWith("@testdatabase.com"));
        assert(!dbEmail.hasHeader("references"));
        assert(dbEmail.textParts.length == 1);

        // Test2: Update draft, no reply
        apiEmail.id        = dbEmail.id;
        apiEmail.messageId = dbEmail.messageId;
        dbEmail            = new Email(apiEmail, "");
        dbEmail.userId     = user.id;
        dbEmail.store();
        assert(dbEmail.id == apiEmail.id);
        assert(dbEmail.messageId == apiEmail.messageId);
        assert(!dbEmail.hasHeader("references"));
        assert(dbEmail.textParts.length == 1);

        // Test3: New draft, reply
        auto emailRepliedObject = getTestDbEmail("testuser", 0, 1);
        auto emailReferences    = emailRepliedObject.getHeader("references").addresses;

        apiEmail.id        = "";
        apiEmail.messageId = "";
        apiEmail.bodyPlain = "I cant do html";

        dbEmail        = new Email(apiEmail, emailRepliedObject.id);
        dbEmail.userId = user.id;
        dbEmail.store();
        assert(dbEmail.id.length);
        assert(dbEmail.messageId.endsWith("@testdatabase.com"));
        assert(dbEmail.getHeader("references").addresses.length ==
                emailReferences.length + 1);
        auto replyToHeader = dbEmail.getHeader("in-reply-to");
        assert(replyToHeader.addresses[0] == emailRepliedObject.messageId);
        assert(replyToHeader.rawValue == emailRepliedObject.messageId);
        assert(dbEmail.textParts.length == 2);

        // Test4: Update draft, reply
        apiEmail.id = dbEmail.id;
        apiEmail.messageId = dbEmail.messageId;
        apiEmail.bodyHtml = "";
        dbEmail = new Email(apiEmail, emailRepliedObject.id);
        dbEmail.userId = user.id;
        dbEmail.store();
        assert(dbEmail.id == apiEmail.id);
        assert(dbEmail.messageId == apiEmail.messageId);
        assert(dbEmail.getHeader("references").addresses.length ==
                emailReferences.length + 1);
        assert(dbEmail.textParts.length == 1);
    }

    unittest // jsonizeHeader
    {
        writeln("Testing Email.jsonizeHeader");
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test", "testemails");

        auto inEmail = new IncomingEmail();
        auto testMailPath = buildPath(backendTestEmailsDir, "simple_alternative_noattach");
        inEmail.loadFromFile(testMailPath, getConfig.attachmentStore);
        auto emailDb = new Email(inEmail);

        assert(emailDb.jsonizeHeader("to") ==
                `"to": " Test User2 <testuser@testdatabase.com>",`);
        assert(emailDb.jsonizeHeader("Date", Yes.RemoveQuotes, Yes.OnlyValue) ==
                `" Sat, 25 Dec 2010 13:31:57 +0100",`);
    }


    unittest // test email.deleted
    {
        writeln("Testing Email.deleted");
        recreateTestDb();
        // insert a new email with deleted = true
        string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend",
                                                "test", "testemails");
        auto inEmail = scoped!IncomingEmail();
        auto mailname = "simple_alternative_noattach";
        inEmail.loadFromFile(buildPath(backendTestEmailsDir, mailname),
                             getConfig.absAttachmentStore);
        auto dbEmail = new Email(inEmail);
        auto user = User.getFromAddress("anotherUser@testdatabase.com");
        dbEmail.userId = user.id;
        dbEmail.deleted = true;
        auto id = dbEmail.store();

        // check that the doc has the deleted
        auto dbEmail2 = Email.get(id);
        assert(dbEmail2 !is null);
        assert(dbEmail2.deleted);

        // check that the conversation has the link.deleted for this email set to true
        Conversation.addEmail(dbEmail, ["inbox"], []);
        auto conv = Conversation.getByReferences(user.id, [dbEmail.messageId],
                                                 Yes.WithDeleted);
        assert(conv !is null);
        foreach(ref msglink; conv.links)
        {
            if (msglink.messageId == dbEmail.messageId)
            {
                assert(msglink.deleted);
                assert(msglink.emailDbId == id);
                break;
            }
        }
    }

    import webbackend.apiemail: ApiEmail;

    ApiEmail getTestApiEmail()
    {
        auto apiEmail      = new ApiEmail();
        apiEmail.from      = "anotherUser@testdatabase.com";
        apiEmail.to        = "juanjo@juanjoalvarez.net";
        apiEmail.subject   = "test of forceInsertNew";
        apiEmail.isoDate   = "2014-08-22T09:22:46";
        apiEmail.date      = "Fri, 22 Aug 2014 09:22:46 +02:00";
        apiEmail.bodyPlain = "test body";
        return apiEmail;
    }


    unittest // toRFCEmail
    {
        recreateTestDb();
        writeln("Testing Email.toRFCEmail");
        Email dbEmail = null;
        Email dbEmail2 = null;
        IncomingEmail inEmail = null;
        string tmpFilePath = buildPath(getConfig().absRawEmailStore, "testfile.email");

        dbEmail = getTestDbEmail("testuser", 0, 0);
        auto f = File(tmpFilePath, "w");
        f.write(dbEmail.toRFCEmail); f.flush(); f.close();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
        dbEmail2 = new Email(inEmail);
        assertEmailsEqual(dbEmail, dbEmail2);

        dbEmail = getTestDbEmail("testuser", 0, 1);
        f = File(tmpFilePath, "w");
        f.write(dbEmail.toRFCEmail); f.flush(); f.close();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
        dbEmail2 = new Email(inEmail);
        assertEmailsEqual(dbEmail, dbEmail2);

        dbEmail = getTestDbEmail("anotherUser", 0, 0);
        f = File(tmpFilePath, "w");
        f.write(dbEmail.toRFCEmail); f.flush(); f.close();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
        dbEmail2 = new Email(inEmail);
        assertEmailsEqual(dbEmail, dbEmail2);

        dbEmail = getTestDbEmail("anotherUser", 1, 2);
        f = File(tmpFilePath, "w");
        f.write(dbEmail.toRFCEmail); f.flush(); f.close();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
        dbEmail2 = new Email(inEmail);
        assertEmailsEqual(dbEmail, dbEmail2);

        dbEmail = getTestDbEmail("anotherUser", 2, 0);
        f = File(tmpFilePath, "w");
        f.write(dbEmail.toRFCEmail); f.flush(); f.close();
        inEmail = new IncomingEmail();
        inEmail.loadFromFile(tmpFilePath, getConfig.absAttachmentStore);
        dbEmail2 = new Email(inEmail);
    }


    unittest // send
    {
        recreateTestDb();
        writeln("Testing Email.send(real SMTP)");

        auto dbEmail = getTestDbEmail("testuser", 0, 0);
        dbEmail.from = HeaderValue(" <juanjux@juanjux.mooo.com>", ["juanjux@juanjux.mooo.com"]);
        dbEmail.receivers = ["juanjux@gmail.com"];
        dbEmail.draft = true;
        assert(dbEmail.send().success);

        // dbEmail = getTestDbEmail("testuser", 0, 1);
        // dbEmail.from = HeaderValue(" <juanjux@juanjux.mooo.com>", ["juanjux@juanjux.mooo.com"]);
        // dbEmail.receivers = ["juanjux@gmail.com"];
        // dbEmail.draft = true;
        // assert(dbEmail.send().success);

        // dbEmail = getTestDbEmail("testuser", 0, 1);
        // dbEmail.from = HeaderValue(" <juanjux@juanjux.mooo.com>", ["juanjux@juanjux.mooo.com"]);
        // dbEmail.receivers = ["juanjux@gmail.com"];
        // dbEmail.draft = true;
        // assert(dbEmail.send().success);
    }

    version(MongoDriver)
    {
        import db.mongo.mongo;
        import db.mongo.driveremailmongo;
        import vibe.data.bson;


        /**
           Get the email at pos emailPos inside the conversation returned
           as convPos on the inbox. Used for test
        */
        Email getTestDbEmail(string user, uint convPos, uint emailPos)
        {
            auto convs       = Conversation.getByTag("inbox", USER_TO_ID[user]);
            auto conv        = Conversation.get(convs[convPos].id);
            auto emailDbId   = conv.links[emailPos].emailDbId;
            auto emailObject = Email.get(emailDbId);
            if (emailObject is null)
                throw new Exception("NO EMAIL IN THAT POSITION!");
            return emailObject;
        }

        unittest // headerRaw
        {
            recreateTestDb();
            writeln("Testing DriverEmailMongo.headerRaw");
            auto bson = parseJsonString("{}");
            auto emailDoc = collection("email").findOne(bson);
            assert(DriverEmailMongo.headerRaw(emailDoc, "delivered-to") == " testuser@testdatabase.com");
            assert(DriverEmailMongo.headerRaw(emailDoc, "date") == " Mon, 27 May 2013 07:42:30 +0200");
            assert(!DriverEmailMongo.headerRaw(emailDoc, "inventedHere").length);
        }

        unittest // extractAttachNamesFromDoc
        {
            recreateTestDb();
            writeln("Testing DriverEmailMongo.extractAttachNamesFromDoc");
            auto bson = parseJsonString("{}");
            auto emailDoc = collection("email").findOne(bson);
            auto attachNames = DriverEmailMongo.extractAttachNamesFromDoc(emailDoc);
            assert(attachNames == ["google.png", "profilephoto.jpeg"]);
        }

        unittest // messageIdToDbId
        {
            writeln("Testing DriverEmailMongo.messageIdToDbId");
            recreateTestDb();
            auto emailMongo = scoped!DriverEmailMongo();
            auto id1 = emailMongo.messageIdToDbId("CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
            auto id2 = emailMongo.messageIdToDbId("AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
            auto id3 = emailMongo.messageIdToDbId("CAGA-+RScZe0tqmG4rbPTSrSCKT8BmkNAGBUOgvCOT5ywycZzZA@mail.gmail.com");
            auto id4 = emailMongo.messageIdToDbId("doesntexist");

            assert(id4 == "");
            assert((id1.length == id2.length) && (id3.length == id1.length) && id1.length == 24);
            auto arr = [id1, id2, id3, id4];
            assert(std.algorithm.count(arr, id1) == 1);
            assert(std.algorithm.count(arr, id2) == 1);
            assert(std.algorithm.count(arr, id3) == 1);
            assert(std.algorithm.count(arr, id4) == 1);
        }

        unittest // getSummary
        {
            writeln("Testing DriverEmailMongo.getSummary");
            recreateTestDb();

            auto emailMongo = scoped!DriverEmailMongo();
            auto convs    = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            auto conv     = Conversation.get(convs[2].id);
            assert(conv !is null);
            auto summary = emailMongo.getSummary(conv.links[0].emailDbId);
            assert(summary.id == conv.links[0].emailDbId);
            assert(summary.from == " Some Random User <someuser@somedomain.com>");
            assert(summary.isoDate == "2014-01-21T14:32:20Z");
            assert(summary.date == " Tue, 21 Jan 2014 15:32:20 +0100");
            assert(summary.bodyPeek == "");
            assert(summary.avatarUrl == "");
            assert(summary.attachFileNames == ["C++ Pocket Reference.pdf"]);

            conv = Conversation.get(convs[0].id);
            assert(conv !is null);
            summary = emailMongo.getSummary(conv.links[0].emailDbId);
            assert(summary.id == conv.links[0].emailDbId);
            assert(summary.from == " SupremacyHosting.com Sales <brian@supremacyhosting.com>");
            assert(summary.isoDate.length);
            assert(summary.date == "");
            assert(summary.bodyPeek == "Well it is speculated that there are over 20,000 "~
                    "hosting companies in this country alone. WIth that ");
            assert(summary.avatarUrl == "");
            assert(!summary.attachFileNames.length);
        }

        unittest // DriverEmailMongo.getOriginal
        {
            writeln("Testing DriverEmailMongo.getOriginal");
            recreateTestDb();

            auto emailMongo = scoped!DriverEmailMongo();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            auto conv = Conversation.get(convs[2].id);
            assert(conv !is null);
            auto rawText = emailMongo.getOriginal(conv.links[0].emailDbId);

            assert(toHexString(md5Of(rawText)) == "CFA0B90028C9E6C5130C5526ABB61F1F");
            assert(rawText.length == 1867294);
        }


        unittest // DriverEmailMongo.addAttachment
        {
            writeln("Testing DriverEmailMongo.addAttachment");
            recreateTestDb();

            // add
            auto emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            auto emailDbId = bsonStr(emailDoc._id);

            ApiAttachment apiAttach;
            apiAttach.ctype = "text/plain";
            apiAttach.filename = "helloworld.txt";
            apiAttach.contentId = "someContentId";
            apiAttach.size = 12;
            string base64content = "aGVsbG8gd29ybGQ="; // "hello world"
            auto emailMongo = scoped!DriverEmailMongo();
            auto attachId = emailMongo.addAttachment(emailDbId, apiAttach, base64content);

            emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            assert(emailDoc.attachments.length == 3);
            auto attachDoc = emailDoc.attachments[2];
            assert(attachId == bsonStr(attachDoc.id));
            auto realPath = bsonStr(attachDoc.realPath);
            assert(realPath.exists);
            auto f = File(realPath, "r");
            ubyte[500] buffer;
            auto readBuf = f.rawRead(buffer);
            string fileContent = cast(string)readBuf.idup;
            assert(fileContent == "hello world");
        }


        unittest // DriverEmailMongo.deleteAttachment
        {
            writeln("Testing DriverEmailMongo.deleteAttachment");
            recreateTestDb();
            auto emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            auto emailDbId = bsonStr(emailDoc._id);
            assert(emailDoc.attachments.length == 2);
            auto attachId = bsonStr(emailDoc.attachments[0].id);
            auto attachPath = bsonStr(emailDoc.attachments[0].realPath);
            auto dbMongo = scoped!DriverEmailMongo();
            dbMongo.deleteAttachment(emailDbId, attachId);

            emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            assert(emailDoc.attachments.length == 1);
            assert(bsonStr(emailDoc.attachments[0].id) != attachId);
            assert(!attachPath.exists);
        }

        unittest // setDeleted
        {
            writeln("Testing DriverEmailMongo.setDeleted");
            recreateTestDb();

            auto emailMongo = scoped!DriverEmailMongo();
            string messageId = "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com";
            auto id = emailMongo.messageIdToDbId(messageId);

            emailMongo.setDeleted(id, true);
            auto emailDoc = collection("email").findOne(["_id": id]);
            assert(bsonBool(emailDoc.deleted));

            emailMongo.setDeleted(id, false);
            emailDoc = collection("email").findOne(["_id": id]);
            assert(!bsonBool(emailDoc.deleted));
        }

        unittest // storeTextIndex
        {
            writeln("Testing DriverEmailMongo.storeTextIndex");
            recreateTestDb();

            auto findJson = `{"$text": {"$search": "DOESNTEXISTS"}}`;
            auto cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(cursor.empty);

            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            findJson = `{"$text": {"$search": "text inside"}}`;
            cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(!cursor.empty);
            assert(bsonStr(cursor.front.userId) == user1.id);
            string res = bsonStr(cursor.front.text);
            assert(countUntil(res, "text inside") == 157);

            findJson = `{"$text": {"$search": "email"}}`;
            cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(!cursor.empty);
            assert(countUntil(toLower(bsonStr(cursor.front.text)), "email") != -1);
            cursor.popFront;
            assert(countUntil(toLower(bsonStr(cursor.front.text)), "email") != -1);
            cursor.popFront;
            assert(cursor.empty);

            findJson = `{"$text": {"$search": "inicio de sesión"}}`;
            cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(!cursor.empty);
            assert(bsonStr(cursor.front.userId) == user1.id);
            res = bsonStr(cursor.front.text);
            auto foundPos = countUntil(res, "inicio de sesión");
            assert(foundPos != -1);

            findJson = `{"$text": {"$search": "inicio de sesion"}}`;
            cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(!cursor.empty);
            res = bsonStr(cursor.front.text);
            auto foundPos2 = countUntil(res, "inicio de sesión");
            assert(foundPos == foundPos2);

            findJson = `{"$text": {"$search": "\"inicio de sesion\""}}`;
            cursor = collection("emailIndexContents").find(parseJsonString(findJson));
            assert(cursor.empty);
        }


        unittest
        {
            writeln("Testing DriverEmailMongo.getReferencesFromPrevious");
            auto emailMongo = scoped!DriverEmailMongo();
            assert(emailMongo.getReferencesFromPrevious("doesntexists").length == 0);

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            auto conv = Conversation.get(convs[0].id);

            auto refs = emailMongo.getReferencesFromPrevious(conv.links[1].emailDbId);
            assert(refs.length == 2);
            auto emailDoc = collection("email").findOne(["_id": conv.links[1].emailDbId]);
            assert(refs[$-1] == bsonStr(emailDoc["message-id"]));

            refs = emailMongo.getReferencesFromPrevious(conv.links[0].emailDbId);
            assert(refs.length == 1);
            emailDoc = collection("email").findOne(["_id": conv.links[0].emailDbId]);
            assert(refs[0] == bsonStr(emailDoc["message-id"]));
        }


        unittest // isOwnedBy
        {
            writeln("Testing DriverEmailMongo.isOwnedBy");
            recreateTestDb();
            auto emailMongo = scoped!DriverEmailMongo();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
            assert(user1 !is null);
            assert(user2 !is null);

            auto cursor = DriverEmailMongo.getEmailCursorAtPosition(0);
            auto email1 = cursor.front;
            assert(emailMongo.isOwnedBy(bsonStr(email1._id), user1.loginName));

            cursor.popFront();
            auto email2 = cursor.front;
            assert(emailMongo.isOwnedBy(bsonStr(email2._id), user1.loginName));

            cursor.popFront();
            auto email3 = cursor.front;
            assert(emailMongo.isOwnedBy(bsonStr(email3._id), user2.loginName));

            cursor.popFront();
            auto email4 = cursor.front;
            assert(emailMongo.isOwnedBy(bsonStr(email4._id), user2.loginName));

            cursor.popFront();
            auto email5 = cursor.front;
            assert(emailMongo.isOwnedBy(bsonStr(email5._id), user2.loginName));
        }

        unittest // purgeById
        {
            struct EmailFiles
            {
                string rawEmail;
                string[] attachments;
            }

            // get the files on filesystem from the email (raw an attachments)
            EmailFiles getEmailFiles(string id)
            {
                auto doc = collection("email").findOne(["_id": id]);
                assert(!doc.isNull);

                auto res = EmailFiles(bsonStr(doc.rawEmailPath));

                foreach(ref attach; doc.attachments)
                {
                    if (!attach.realPath.isNull)
                        res.attachments ~= bsonStr(attach.realPath);
                }
                return res;
            }

            void assertNoFiles(EmailFiles ef)
            {
                assert(!ef.rawEmail.exists);
                foreach(ref att; ef.attachments)
                    assert(!att.exists);
            }

            writeln("Testing DriverEmailMongo.purgeById");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            auto singleMailConv = convs[0];
            auto singleMailId   = singleMailConv.links[0].emailDbId;

            auto emailFiles = getEmailFiles(singleMailId);
            Email.purgeById(singleMailId);
            auto emailDoc = collection("email").findOne(["_id": singleMailId]);
            assert(emailDoc.isNull);
            assertNoFiles(emailFiles);

            auto fakeMultiConv = convs[1];
            auto fakeMultiConvEmailId = fakeMultiConv.links[2].emailDbId;
            emailFiles = getEmailFiles(fakeMultiConvEmailId);
            Email.purgeById(fakeMultiConvEmailId);
            emailDoc = collection("email").findOne(["_id": fakeMultiConvEmailId]);
            assert(emailDoc.isNull);
            assertNoFiles(emailFiles);

            auto multiConv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
            auto multiConvEmailId = multiConv.links[0].emailDbId;
            emailFiles = getEmailFiles(multiConvEmailId);
            Email.purgeById(multiConvEmailId);
            emailDoc = collection("email").findOne(["_id": multiConvEmailId]);
            assert(emailDoc.isNull);
            assertNoFiles(emailFiles);
        }

        unittest // store()
        {
            writeln("Testing DriverEmailMongo.store");
            recreateTestDb();
            // recreateTestDb already calls email.store, check that the inserted email is fine
            auto emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            assert(emailDoc.headers.references[0].addresses.length == 1);
            assert(bsonStr(emailDoc.headers.references[0].addresses[0]) ==
                    "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com");
            assert(bsonStr(emailDoc.headers.subject[0].rawValue) ==
                    " Fwd: Se ha evitado un inicio de sesión sospechoso");
            assert(emailDoc.attachments.length == 2);
            assert(bsonStr(emailDoc.attachments[0].id).length);
            assert(bsonStr(emailDoc.attachments[1].id).length);
            assert(bsonStr(emailDoc.isodate) == "2013-05-27T05:42:30Z");
            assert(bsonStrArray(emailDoc.receivers) == ["testuser@testdatabase.com"]);
            assert(bsonStr(emailDoc.from.addresses[0]) == "someuser@somedomain.com");
            assert(emailDoc.textParts.length == 2);
            assert(bsonStr(emailDoc.bodyPeek) == "Some text inside the email plain part");

            // check generated msgid
            auto cursor = DriverEmailMongo.getEmailCursorAtPosition(
                    countUntil(db.test_support.TEST_EMAILS, "spam_notagged_nomsgid")
            );
            assert(bsonStr(cursor.front["message-id"]).length);
            assert(bsonStr(cursor.front.bodyPeek) == "Well it is speculated that there are over 20,000 hosting companies in this country alone. WIth that ");
        }

        unittest
        {
            writeln("Testing DriverEmailMongo.store(forceInsertNew)");
            recreateTestDb();
            auto emailMongo = scoped!DriverEmailMongo();

            auto apiEmail = getTestApiEmail();
            auto dbEmail = new Email(apiEmail);
            dbEmail.userId = "xxx";
            auto idFirst = emailMongo.store(dbEmail); // new
            apiEmail.id = idFirst;
            dbEmail = new Email(apiEmail);
            dbEmail.userId = "xxx";
            auto idSame = emailMongo.store(dbEmail); // no forceInserNew, should have the same id
            assert(idFirst == idSame);

            dbEmail = new Email(apiEmail);
            dbEmail.userId = "xxx";
            auto idDifferent = emailMongo.store(dbEmail, Yes.ForceInsertNew);
            assert(idDifferent != idFirst);
        }

        unittest
        {
            writeln("Testing DriverEmailMongo.store(storeAttachMents");
            recreateTestDb();
            auto emailMongo = scoped!DriverEmailMongo();
            auto apiEmail = getTestApiEmail();
            apiEmail.attachments = [
                ApiAttachment(joinPath("/" ~ getConfig.URLAttachmentPath, "somefilecode.jpg"),
                              "testdbid", "ctype", "fname", "ctId", 1000)
            ];
            auto dbEmail = new Email(apiEmail);
            dbEmail.userId = "xxx";

            // should not store the attachments:
            auto id = emailMongo.store(dbEmail, No.ForceInsertNew, No.StoreAttachMents);
            auto emailDoc = collection("email").findOne(["_id": id]);
            assert(emailDoc.attachments.isNull);

            // should store the attachments
            emailMongo.store(dbEmail, No.ForceInsertNew, Yes.StoreAttachMents);
            emailDoc = collection("email").findOne(["_id": id]);
            assert(!emailDoc.attachments.isNull);
            assert(emailDoc.attachments.length == 1);
        }

        unittest // sendRetries && sendStatus store and retrieval
        {
            writeln("Testing Email sendRetries && sendStatus store and retrieval");
            recreateTestDb();
            auto emailMongo = scoped!DriverEmailMongo();
            auto emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            auto emailId = bsonStr(emailDoc._id);
            auto dbEmail = emailMongo.get(emailId);
            assert(dbEmail.sendStatus == SendStatus.NA);
            assert(dbEmail.sendRetries == 0);
            dbEmail.sendStatus = SendStatus.SENT;
            dbEmail.sendRetries = 10;
            dbEmail.store();

            auto dbEmail2 = emailMongo.get(emailId);
            assert(dbEmail2.sendStatus == SendStatus.SENT);
            assert(dbEmail2.sendRetries == 10);
        }

        unittest // get
        {
            writeln("Testing DriverEmailMongo.get (message about null email is Ok)");
            recreateTestDb();

            auto emailMongo = scoped!DriverEmailMongo();
            auto emailDoc = DriverEmailMongo.getEmailCursorAtPosition(0).front;
            auto emailId  = bsonStr(emailDoc._id);
            auto noEmail = emailMongo.get("noid");
            assert(noEmail is null);

            auto email    = emailMongo.get(emailId);
            assert(email.id.length);
            assert(!email.deleted);
            assert(!email.draft);
            assert(email.from == HeaderValue(" Some User <someuser@somedomain.com>",
                                             ["someuser@somedomain.com"]));
            assert(email.isoDate == "2013-05-27T05:42:30Z");
            assert(email.bodyPeek == "Some text inside the email plain part");
            assert(email.forwardedTo.length == 0);
            assert(email.destinationAddress == "testuser@testdatabase.com");
            assert(email.messageId ==
                    "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
            assert(email.receivers == ["testuser@testdatabase.com"]);
            assert(email.rawEmailPath.length);
            assert(email.attachments.length == 2);
            assert(email.attachments.list[0].ctype == "image/png");
            assert(email.attachments.list[0].filename == "google.png");
            assert(email.attachments.list[0].contentId == "<google>");
            assert(email.attachments.list[0].size == 6321L);
            assert(email.attachments.list[0].id.length);
            assert(email.attachments.list[1].ctype == "image/jpeg");
            assert(email.attachments.list[1].filename == "profilephoto.jpeg");
            assert(email.attachments.list[1].contentId == "<profilephoto>");
            assert(email.attachments.list[1].size == 1063L);
            assert(email.attachments.list[1].id.length);
            assert(email.textParts.length == 2);
            assert(strip(email.textParts[0].content) == "Some text inside the email plain part");
            assert(email.textParts[0].ctype == "text/plain");
            assert(email.textParts[1].ctype == "text/html");
        }
    } // end version DriverMongo
}
