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
module db.tests.test_conversation;

version(db_test)
version(db_usetestdb)
{
    import common.utils;
    import db.conversation;
    import db.mongo.mongo;
    import db.email;
    import db.test_support;
    import db.user;
    import std.stdio;
    import std.typecons;
    import vibe.data.bson;

    unittest // Conversation.hasLink
    {
        writeln("Testing Conversation.hasLink");
        recreateTestDb();
        auto conv        = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        const emailDbId  = conv.links[0].emailDbId;
        const emailMsgId = conv.links[0].messageId;
        assert(conv.hasLink(emailMsgId, emailDbId));
        assert(!conv.hasLink("blabla", emailDbId));
        assert(!conv.hasLink(emailMsgId, "blabla"));
        assert(!conv.hasLink(emailDbId, emailMsgId));
    }

    unittest // Conversation.addLink
    {
        writeln("Testing Conversation.addLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[0];
        assert(conv.links.length == 1);
        // check it doesnt add the same link twice
        const emailDbId = conv.links[0].emailDbId;
        const polompos = conv.links[0].emailDbId;
        const emailMsgId = conv.links[0].messageId;
        const deleted = conv.links[0].deleted;
        string[] attachs = ["someAttachName", "anotherAttachName"];
        conv.addLink(emailMsgId, attachs, emailDbId, deleted);
        assert(conv.links.length == 1);
        assert(!conv.links[0].attachNames.length);

        // check that it adds a new link
        conv.addLink("someMessageId", attachs, "someEmailDbId", false);
        assert(conv.links.length == 2);
        assert(conv.links[1].messageId == "someMessageId");
        assert(conv.links[1].emailDbId == "someEmailDbId");
        assert(!conv.links[1].deleted);
        assert(conv.links[1].attachNames == attachs);
    }

    unittest // Conversation.removeLink
    {
        writeln("Testing Conversation.removeLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[1];
        assert(conv.links.length == 3);
        const link0 = conv.links[0];
        const link1 = conv.links[1];
        const emailId = conv.links[2].emailDbId;
        conv.removeLink(emailId);
        assert(conv.links.length == 2);
        assert(conv.links[0].messageId == link0.messageId);
        assert(conv.links[0].emailDbId == link0.emailDbId);
        assert(conv.links[1].messageId == link1.messageId);
        assert(conv.links[1].emailDbId == link1.emailDbId);
    }

    unittest // Conversation.receivedLinks
    {
        writeln("Testing Conversation.receivedLinks");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[0];
        assert(conv.links.length == 1);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[1];
        assert(conv.links.length == 3);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"])[2];
        assert(conv.links.length == 1);
        assert(conv.receivedLinks.length == 1);

        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(conv.links.length == 2);
        assert(conv.receivedLinks.length == 2);
        auto convId = conv.id;
        foreach(ref link; conv.receivedLinks)
            link.deleted = true;
        conv.store();
        conv = Conversation.get(convId);
        assert(conv.links[0].deleted);
        assert(conv.links[1].deleted);
    }


    unittest // search
    {
        import db.user;
        import db.email;
        // Not the same as the searchEmails test because "search" returns conversations
        // with several messages grouped (thus, less results sometimes)
        writeln("Testing Conversation.search");
        recreateTestDb();
        auto user1id = USER_TO_ID["testuser"];
        auto user2id = USER_TO_ID["anotherUser"];
        auto searchResults = Conversation.search(["inicio de sesión"], user1id);
        assert(searchResults.length == 1);
        assert(searchResults[0].matchingEmailsIdx == [1]);

        auto searchResults2 = Conversation.search(["some"], user2id);
        assert(searchResults2.length == 2);

        auto searchResults3 = Conversation.search(["some"], user2id, "2014-06-01T14:32:20Z");
        assert(searchResults3.length == 1);
        auto searchResults4 = Conversation.search(["some"], user2id, "2014-08-01T14:32:20Z");
        assert(searchResults4.length == 0);
        auto searchResults4b = Conversation.search(["some"], user2id, "2018-05-28T14:32:20Z");
        assert(searchResults4b.length == 0);

        string startFixedDate = "2005-01-01T00:00:00Z";
        auto searchResults5 = Conversation.search(["some"], user2id, startFixedDate,
                                           "2018-12-12T00:00:00Z");
        assert(searchResults5.length == 2);
        auto searchResults5b = Conversation.search(["some"], user2id, startFixedDate,
                                            "2014-02-01T00:00:00Z");
        assert(searchResults5b.length == 1);
        assert(searchResults5b[0].matchingEmailsIdx.length == 1);
        auto searchResults5c = Conversation.search(["some"], user2id, startFixedDate,
                                            "2015-02-21T00:00:00Z");
        assert(searchResults5c.length == 2);
    }


    unittest // Conversation.setLinkDeleted
    {
        writeln("Testing Conversation.setLinkDeleted");
        recreateTestDb();

        auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        conv.setLinkDeleted(conv.links[0].emailDbId, true);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(conv.links[0].deleted);
        auto email = Email.get(conv.links[0].emailDbId);
        assert(email !is null);
        assert(email.deleted);

        conv.setLinkDeleted(conv.links[0].emailDbId, false);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(!conv.links[0].deleted);
        email = Email.get(conv.links[0].emailDbId);
        assert(email !is null);
        assert(!email.deleted);
    }

    version(MongoDriver)
    {
        import db.mongo.driverconversationmongo;

        unittest // isOwnedBy
        {
            writeln("Testing DriverConversationMongo.isOwnedBy");
            recreateTestDb();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");

            auto conv = Conversation.getByReferences(user1.id,
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(Conversation.isOwnedBy(conv.id, user1.loginName));

            conv = Conversation.getByReferences(user2.id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(Conversation.isOwnedBy(conv.id, user2.loginName));
        }

        unittest // searchEmails
        {
            import db.user;
            writeln("Testing DriverConversationMongo.searchEmails");
            recreateTestDb();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
            auto convMongo = scoped!DriverConversationMongo();
            auto results = convMongo.searchEmails(["inicio de sesión"], user1.id);
            assert(results.length == 1);
            auto conv  = Conversation.get(results[0].convId);
            assert(conv.links[1].emailDbId == results[0].emailId);

            auto results2 = convMongo.searchEmails(["some"], user1.id);
            assert(results2.length == 2);
            foreach(ref result; results2)
            {
                conv = Conversation.get(result.convId);
                bool found = false;
                foreach(ref link; conv.links)
                {
                    if (link.emailDbId == result.emailId)
                    {
                        found = true;
                        break;
                    }
                }
                assert(found);
            }

            auto results3 = convMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z");
            assert(results3.length == 1);

            auto results4 = convMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z",
                                                     "2014-08-01T00:00:00Z");
            assert(results4.length == 1);

            string startFixedDate = "2005-01-01T00:00:00Z";
            auto results5 = convMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                     "2018-12-12T00:00:00Z");
            assert(results5.length == 2);

            auto results6 = convMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                     "2014-06-01T00:00:00Z");
            assert(results6.length == 1);
        }

        unittest // get/docToObject
        {
            writeln("Testing DriverConversationMongo.get/docToObject");
            recreateTestDb();

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length == 1);
            auto conv  = Conversation.get(convs[0].id);
            assert(conv !is null);
            assert(conv.lastDate.length); // this email date is set to NOW
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 2);
            assert(conv.links[1].attachNames == ["google.png", "profilephoto.jpeg"]);
            assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
            assert(conv.links[0].deleted == false);

            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            conv = Conversation.get(convs[1].id);
            assert(conv !is null);
            assert(conv.lastDate == "2014-06-10T12:51:10Z");
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 3);
            assert(!conv.links[0].attachNames.length);
            assert(!conv.links[1].attachNames.length);
            assert(!conv.links[2].attachNames.length);
            assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
            assert(!conv.links[0].deleted);
            assert(!conv.links[1].deleted);
            assert(!conv.links[2].deleted);

            conv = Conversation.get(convs[2].id);
            assert(conv !is null);
            assert(conv.lastDate == "2014-01-21T14:32:20Z");
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 1);
            assert(conv.links[0].attachNames.length == 1);
            assert(conv.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
            assert(conv.cleanSubject == " Attachment test");
            assert(conv.links[0].deleted == false);
        }



        unittest // getByEmailId
        {
            writeln("Testing DriverConversationMongo.getByEmailId");
            recreateTestDb();

            auto conv = Conversation.getByReferences(USER_TO_ID["testuser"],
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);

            auto conv2 = Conversation.getByEmailId(conv.links[0].emailDbId);
            assert(conv2 !is null);
            assert(conv.id == conv2.id);

            auto conv3 = Conversation.getByEmailId("doesntexist");
            assert(conv3 is null);
        }

        unittest // addTagDb / removeTagDb
        {
            writeln("Testing DriversConversationMongo.addTagDb");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length);
            auto id = convs[0].id;
            DriverConversationMongo.addTagDb(id, "testTag");
            auto conv = Conversation.get(id);
            assert(conv !is null);
            assert(conv.hasTag("testtag"));

            writeln("Testing DriverConversationMongo.removeTagDb");
            DriverConversationMongo.removeTagDb(id, "testTag");
            conv = Conversation.get(id);
            assert(!conv.hasTag("testtag"));
        }

        unittest // remove
        {
            writeln("Testing DriverConversationMongo.remove (message about null emails is Ok)");
            recreateTestDb();
            auto convs = Conversation.getByTag( "inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            const id = convs[0].id;
            string[] linkIds;
            foreach(ref link; convs[0].links)
                linkIds ~= link.emailDbId.idup;
            convs[0].remove();
            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 2);
            foreach(conv; convs)
                assert(conv.id != id);
            foreach(ref linkId; linkIds)
            {
                auto email = Email.get(linkId);
                assert(email is null);
            }
        }

        unittest // getByTag
        {
            writeln("Testing DriverConversationMongo.getByTag");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            assert(convs[0].lastDate > convs[2].lastDate);
            assert(convs[0].links[0].deleted == false);

            auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 0);
            assert(convs2.length == 2);
            assert(convs2[0].id == convs[0].id);
            assert(convs2[1].id == convs[1].id);
            assert(convs2[0].links[0].deleted == false);
            assert(convs2[1].links[0].deleted == false);

            auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 1);
            assert(convs3.length == 1);
            assert(convs3[0].id == convs[2].id);

            auto convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
            assert(convs4[0].id == convs[0].id);
            assert(convs4[1].id == convs[1].id);
            assert(convs4[2].id == convs[2].id);
            assert(convs4[0].links[0].deleted == false);
            assert(convs4[1].links[0].deleted == false);
            assert(convs4[2].links[0].deleted == false);

            // check that it doesnt returns the deleted convs
            auto len1 = convs4.length;
            DriverConversationMongo.addTagDb(convs4[0].id, "deleted");
            convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
            assert(convs4.length == len1-1);
            // except when using Yes.WithDeleted
            convs4 = Conversation.getByTag(
                    "inbox", USER_TO_ID["anotherUser"], 1000, 0, Yes.WithDeleted
            );
            assert(convs4.length == len1);
        }

        unittest // getByReferences
        {
            writeln("Testing DriverConversationMongo.getByReferences");
            recreateTestDb();
            immutable user1id = USER_TO_ID["testuser"];
            //immutable user2id = USER_TO_ID["anotherUser"];
            immutable msgId1 =
                "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com";
            immutable msgId2 =
                "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com";

            auto conv = Conversation.getByReferences(user1id, [msgId1]);
            auto dbid1 = conv.id;
            assert(conv !is null);
            assert(conv.id.length);
            assert(conv.lastDate == "2013-05-27T05:42:30Z");
            assert(conv.tagsArray == ["inbox"]);
            assert(conv.links.length == 2);
            assert(conv.links[1].messageId == msgId2);
            assert(conv.links[0].emailDbId.length);
            assert(conv.links[1].emailDbId.length);
            assert(conv.links[0].deleted == false);
            assert(conv.links[1].deleted == false);

            conv = Conversation.getByReferences(user1id, [msgId2]);
            auto dbid2 = conv.id;
            assert(conv !is null);
            assert(dbid1 == dbid2);

            DriverConversationMongo.addTagDb(conv.id, "deleted");
            // check that it doesnt returns the deleted convs
            conv = Conversation.getByReferences(user1id, [msgId2]);
            assert(conv is null);
            // except when using Yes.WithDeleted
            conv = Conversation.getByReferences(user1id, [msgId2], Yes.WithDeleted);
            assert(conv !is null);
        }

        unittest // Conversation.store
        {
            writeln("Testing DriverConversationMongo.store");
            recreateTestDb();

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            // update existing (id doesnt change)
            convs[0].addTag("newtag");
            string[] attachNames = ["one", "two"];
            convs[0].addLink("someMessageId", attachNames);
            auto oldDbId = convs[0].id;
            convs[0].store();

            auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs2.length == 3);
            assert(convs2[0].id == oldDbId);
            assert(convs2[0].hasTag("inbox"));
            assert(convs2[0].hasTag("newtag"));
            assert(convs2[0].numTags == 2);
            assert(convs2[0].links[1].messageId == "someMessageId");
            assert(convs2[0].links[1].attachNames == attachNames);

            // create new (new id)
            convs2[0].id = BsonObjectID.generate().toString;
            convs2[0].store();
            auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs3.length == 4);

            bool found = false;
            foreach(conv; convs3)
            {
                if (conv.id == convs2[0].id)
                {
                    found = true;
                    assert(conv.userDbId == convs2[0].userDbId);
                    assert(conv.lastDate == convs2[0].lastDate);
                    assert(conv.numTags == convs2[0].numTags);
                    assert(convs2[0].hasTags(conv.tagsArray));
                    assert(conv.links[0].attachNames == convs2[0].links[0].attachNames);
                    assert(conv.cleanSubject == convs2[0].cleanSubject);
                    foreach(idx, link; conv.links)
                    {
                        assert(link.messageId == convs2[0].links[idx].messageId);
                        assert(link.emailDbId == convs2[0].links[idx].emailDbId);
                        assert(link.deleted == convs2[0].links[idx].deleted);
                    }
                }
            }
            assert(found);
        }

        unittest // purgeLink
        {
            writeln("Testing Conversation.purgeLink");
            recreateTestDb();

            // test_email.purgeById already checks that emails, rawfile and attach files are
            // correctly deleted, so this test only checks if a conversation is deleted it the
            // email was the last one or not deleted otherwise

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            auto singleMailConv = convs[0];
            auto singleConvId   = singleMailConv.id;
            auto singleMailId   = singleMailConv.links[0].emailDbId;

            // since this is a single mail conversation, it should be deleted when the single
            // email is deleted
            Conversation.purgeLink(singleMailId);
            auto emailDoc = collection("email").findOne(["_id": singleMailId]);
            assert(emailDoc.isNull);
            auto convDoc = collection("conversation").findOne(["_id": singleConvId]);
            assert(convDoc.isNull);

            // conversation with more links, but only one is actually in DB,
            // it should be removed too
            auto fakeMultiConv = convs[1];
            auto fakeMultiConvId = fakeMultiConv.id;
            auto fakeMultiConvEmailId = fakeMultiConv.links[2].emailDbId;
            Conversation.purgeLink(fakeMultiConvEmailId);
            emailDoc = collection("email").findOne(["_id": fakeMultiConvEmailId]);
            assert(emailDoc.isNull);
            convDoc = collection("conversation").findOne(["_id": fakeMultiConvId]);
            assert(convDoc.isNull);

            // conversation with more emails in the DB, the link of the email to
            // remove should be deleted but the conversation should be keept in DB
            auto multiConv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
            auto multiConvId = multiConv.id;
            auto multiConvEmailId = multiConv.links[0].emailDbId;
            Conversation.purgeLink(multiConvEmailId);
            emailDoc = collection("email").findOne(["_id": multiConvEmailId]);
            assert(emailDoc.isNull);
            convDoc = collection("conversation").findOne(["_id": multiConvId]);
            assert(!convDoc.isNull);
            assert(!convDoc.links.isNull);
            assert(convDoc.links.length == 1);
            assert(!convDoc.links[0].emailId.isNull);
            assert(bsonStr(convDoc.links[0].emailId) != multiConvEmailId);
        }

        unittest // addEmail
        {
            import retriever.incomingemail;
            import db.email;

            void assertConversationInEmailIndex(string emailId, string convId)
            {
                auto emailIdxDoc =
                    collection("emailIndexContents").findOne(["emailDbId": emailId]);
                assert(!emailIdxDoc.isNull);
                assert(bsonStr(emailIdxDoc.convId) == convId);
            }

            writeln("Testing DriverConversationMongo.addEmail");
            recreateTestDb();
            string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                                   "testemails");
            auto inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                         getConfig().attachmentStore);

            auto user = User.getFromAddress(inEmail.getHeader("to").addresses[0]);
            assert(user !is null);
            string[] tagsToAdd = ["inbox", "anothertag"];

            // test1: insert as is, should create a new conversation with this email as single
            // member
            auto dbEmail = new Email(inEmail);
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            auto emailId = dbEmail.store();
            auto convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            auto convDoc = findOneById("conversation", convId);

            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId)                 == user.id);
            assert(convDoc.links.type                      == Bson.Type.array);
            assert(convDoc.links.length                    == 1);
            assert(bsonStr(convDoc.links[0]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[0].emailId)       == emailId);
            assert(convDoc.tags.type                       == Bson.Type.Array);
            assert(convDoc.tags.length                     == 2);
            assert(bsonStrArray(convDoc.tags)[0]           == "anothertag");
            assert(bsonStrArray(convDoc.tags)[1]           == "inbox");
            assert(bsonStr(convDoc.lastDate)               == dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            auto convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id     == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[0].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[0].emailDbId == emailId);
            assert(!convObject.links[0].attachNames.length);
            assert(convObject.links[0].deleted == false);


            // test2: insert as a msgid of a reference already on a conversation, check that the right
            // conversationId is returned and the emailId added to its entry in the conversation.links
            recreateTestDb();
            inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                               getConfig().attachmentStore);
            dbEmail = new Email(inEmail);
            auto testMsgId = "testreference@blabla.testdomain.com";
            inEmail.removeHeader("message-id");
            inEmail.addHeader("Message-ID: " ~ testMsgId);
            dbEmail.messageId = testMsgId;
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            emailId = dbEmail.store();
            convId = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            convDoc = findOneById("conversation", convId);
            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId) == user.id);
            assert(convDoc.links.type == Bson.Type.array);
            assert(convDoc.links.length == 3);
            assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
            assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[1].emailId) == emailId);
            assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[1].messageId == dbEmail.messageId);
            assert(convObject.links[1].emailDbId == emailId);
            assert(!convObject.links[1].attachNames.length);
            assert(convObject.links[0].deleted == false);

            // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
            // is added to that conversation
            recreateTestDb();
            inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                               getConfig().attachmentStore);
            string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
            inEmail.addHeader(refHeader);
            dbEmail = new Email(inEmail);
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            emailId = dbEmail.store();
            convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            convDoc = findOneById("conversation", convId);

            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId) == user.id);
            assert(convDoc.links.type == Bson.Type.array);
            assert(convDoc.links.length == 2);
            assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
            assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[1].emailId) == emailId);
            assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[1].messageId == dbEmail.messageId);
            assert(convObject.links[1].emailDbId == emailId);
            assert(!convObject.links[1].attachNames.length);
            assert(convObject.links[1].deleted == false);
            assert(convObject.links[0].attachNames.length);
            assert(convObject.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
        }

        unittest // get/docToObject
        {
            writeln("Testing DriverConversationMongo.get/docToObject");
            recreateTestDb();

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length == 1);
            auto conv  = Conversation.get(convs[0].id);
            assert(conv !is null);
            assert(conv.lastDate.length); // this email date is set to NOW
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 2);
            assert(conv.links[1].attachNames == ["google.png", "profilephoto.jpeg"]);
            assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
            assert(conv.links[0].deleted == false);

            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            conv = Conversation.get(convs[1].id);
            assert(conv !is null);
            assert(conv.lastDate == "2014-06-10T12:51:10Z");
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 3);
            assert(!conv.links[0].attachNames.length);
            assert(!conv.links[1].attachNames.length);
            assert(!conv.links[2].attachNames.length);
            assert(conv.cleanSubject == " Fwd: Hello My Dearest, please I need your help! POK TEST\n");
            assert(conv.links[0].deleted == false);

            conv = Conversation.get(convs[2].id);
            assert(conv !is null);
            assert(conv.lastDate == "2014-01-21T14:32:20Z");
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 1);
            assert(conv.links[0].attachNames.length == 1);
            assert(conv.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
            assert(conv.cleanSubject == " Attachment test");
            assert(conv.links[0].deleted == false);
        }


        unittest // getByTag
        {
            writeln("Testing DriverConversationMongo.getByTag");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            assert(convs[0].lastDate > convs[2].lastDate);
            assert(convs[0].links[0].deleted == false);

            auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 0);
            assert(convs2.length == 2);
            assert(convs2[0].id == convs[0].id);
            assert(convs2[1].id == convs[1].id);
            assert(convs2[0].links[0].deleted == false);
            assert(convs2[1].links[0].deleted == false);

            auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 1);
            assert(convs3.length == 1);
            assert(convs3[0].id == convs[2].id);

            auto convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
            assert(convs4[0].id == convs[0].id);
            assert(convs4[1].id == convs[1].id);
            assert(convs4[2].id == convs[2].id);
            assert(convs4[0].links[0].deleted == false);
            assert(convs4[1].links[0].deleted == false);
            assert(convs4[2].links[0].deleted == false);

            // check that it doesnt returns the deleted convs
            auto len1 = convs4.length;
            DriverConversationMongo.addTagDb(convs4[0].id, "deleted");
            convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
            assert(convs4.length == len1-1);
            // except when using Yes.WithDeleted
            convs4 = Conversation.getByTag(
                    "inbox", USER_TO_ID["anotherUser"], 1000, 0, Yes.WithDeleted
            );
            assert(convs4.length == len1);
        }


        unittest // getByReferences
        {
            writeln("Testing DriverConversationMongo.getByReferences");
            recreateTestDb();
            auto user1id = USER_TO_ID["testuser"];
            auto user2id = USER_TO_ID["anotherUser"];

            auto conv = Conversation.getByReferences(user1id,
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(conv.lastDate == "2013-05-27T05:42:30Z");
            assert(conv.tagsArray == ["inbox"]);
            assert(conv.links.length == 2);
            assert(conv.links[1].messageId ==
                    "CAAfONcs2L4Y68aPxihL9Hk0PnuapXgKr0ZGP6z4HjPLqOv+PWg@mail.gmail.com");
            assert(conv.links[0].emailDbId.length);
            assert(conv.links[1].emailDbId.length);
            assert(conv.links[0].deleted == false);
            assert(conv.links[1].deleted == false);


            conv = Conversation.getByReferences(user2id, ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(conv.lastDate == "2014-01-21T14:32:20Z");
            assert(conv.tagsArray == ["inbox"]);
            assert(conv.links.length == 1);
            assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
            assert(conv.links[0].emailDbId.length);
            assert(conv.links[0].deleted == false);

            DriverConversationMongo.addTagDb(conv.id, "deleted");
            // check that it doesnt returns the deleted convs
            conv = Conversation.getByReferences(user2id,
                    ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
            assert(conv is null);
            // except when using Yes.WithDeleted
            conv = Conversation.getByReferences(user2id,
                    ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"],
                    Yes.WithDeleted);
            assert(conv !is null);
        }


        unittest // getByEmailId
        {
            writeln("Testing DriverConversationMongo.getByEmailId");
            recreateTestDb();

            auto conv = Conversation.getByReferences(USER_TO_ID["testuser"],
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);

            auto conv2 = Conversation.getByEmailId(conv.links[0].emailDbId);
            assert(conv2 !is null);
            assert(conv.id == conv2.id);

            auto conv3 = Conversation.getByEmailId("doesntexist");
            assert(conv3 is null);
        }


        unittest // addTagDb / removeTagDb
        {
            writeln("Testing DriversConversationMongo.addTagDb");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length);
            auto id = convs[0].id;
            DriverConversationMongo.addTagDb(id, "testTag");
            auto conv = Conversation.get(id);
            assert(conv !is null);
            assert(conv.hasTag("testtag"));

            writeln("Testing DriverConversationMongo.removeTagDb");
            DriverConversationMongo.removeTagDb(id, "testTag");
            conv = Conversation.get(id);
            assert(!conv.hasTag("testtag"));
        }

        unittest // remove
        {
            writeln("Testing DriverConversationMongo.remove");
            recreateTestDb();
            auto convs = Conversation.getByTag( "inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            const id = convs[0].id;
            convs[0].remove();
            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 2);
            foreach(conv; convs)
                assert(conv.id != id);
        }

        unittest // addEmail
        {
            import retriever.incomingemail;
            import db.email;

            void assertConversationInEmailIndex(string emailId, string convId)
            {
                auto emailIdxDoc =
                    collection("emailIndexContents").findOne(["emailDbId": emailId]);
                assert(!emailIdxDoc.isNull);
                assert(bsonStr(emailIdxDoc.convId) == convId);
            }

            writeln("Testing DriverConversationMongo.addEmail");
            recreateTestDb();
            string backendTestEmailsDir = buildPath(getConfig().mainDir, "backend", "test",
                                                   "testemails");
            auto inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                                         getConfig().attachmentStore);

            auto user = User.getFromAddress(inEmail.getHeader("to").addresses[0]);
            assert(user !is null);
            string[] tagsToAdd = ["inbox", "anothertag"];

            // test1: insert as is, should create a new conversation with this email as single
            // member
            auto dbEmail = new Email(inEmail);
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            auto emailId = dbEmail.store();
            auto convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            auto convDoc = findOneById("conversation", convId);

            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId)                 == user.id);
            assert(convDoc.links.type                      == Bson.Type.array);
            assert(convDoc.links.length                    == 1);
            assert(bsonStr(convDoc.links[0]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[0].emailId)       == emailId);
            assert(convDoc.tags.type                       == Bson.Type.Array);
            assert(convDoc.tags.length                     == 2);
            assert(bsonStrArray(convDoc.tags)[0]           == "anothertag");
            assert(bsonStrArray(convDoc.tags)[1]           == "inbox");
            assert(bsonStr(convDoc.lastDate)               == dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            auto convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id     == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[0].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[0].emailDbId == emailId);
            assert(!convObject.links[0].attachNames.length);
            assert(convObject.links[0].deleted == false);


            // test2: insert as a msgid of a reference already on a conversation, check that the right
            // conversationId is returned and the emailId added to its entry in the conversation.links
            recreateTestDb();
            inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                               getConfig().attachmentStore);
            dbEmail = new Email(inEmail);
            auto testMsgId = "testreference@blabla.testdomain.com";
            inEmail.removeHeader("message-id");
            inEmail.addHeader("Message-ID: " ~ testMsgId);
            dbEmail.messageId = testMsgId;
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            emailId = dbEmail.store();
            convId = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            convDoc = findOneById("conversation", convId);
            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId) == user.id);
            assert(convDoc.links.type == Bson.Type.array);
            assert(convDoc.links.length == 3);
            assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
            assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[1].emailId) == emailId);
            assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[1].messageId == dbEmail.messageId);
            assert(convObject.links[1].emailDbId == emailId);
            assert(!convObject.links[1].attachNames.length);
            assert(convObject.links[0].deleted == false);

            // test3: insert with a reference to an existing conversation doc, check that the email msgid and emailId
            // is added to that conversation
            recreateTestDb();
            inEmail = new IncomingEmail();
            inEmail.loadFromFile(buildPath(backendTestEmailsDir, "html_quoted_printable"),
                               getConfig().attachmentStore);
            string refHeader = "References: <CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com>\r\n";
            inEmail.addHeader(refHeader);
            dbEmail = new Email(inEmail);
            dbEmail.setOwner(dbEmail.localReceivers()[0]);
            assert(dbEmail.destinationAddress == "anotherUser@testdatabase.com");
            emailId = dbEmail.store();
            convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).id;
            convDoc = findOneById("conversation", convId);

            assert(!convDoc.isNull);
            assert(bsonStr(convDoc.userId) == user.id);
            assert(convDoc.links.type == Bson.Type.array);
            assert(convDoc.links.length == 2);
            assert(bsonStr(convDoc.links[1]["message-id"]) == inEmail.getHeader("message-id").addresses[0]);
            assert(bsonStr(convDoc.links[1]["message-id"]) == dbEmail.messageId);
            assert(bsonStr(convDoc.links[1].emailId) == emailId);
            assert(bsonStr(convDoc.lastDate) != dbEmail.isoDate);
            assertConversationInEmailIndex(emailId, convId);

            convObject = Conversation.get(convId);
            assert(convObject !is null);
            assert(convObject.id == convId);
            assert(convObject.userDbId == user.id);
            assert(convObject.lastDate == bsonStr(convDoc.lastDate));
            assert(convObject.hasTags(tagsToAdd));
            assert(convObject.links[1].messageId == inEmail.getHeader("message-id").addresses[0]);
            assert(convObject.links[1].messageId == dbEmail.messageId);
            assert(convObject.links[1].emailDbId == emailId);
            assert(!convObject.links[1].attachNames.length);
            assert(convObject.links[1].deleted == false);
            assert(convObject.links[0].attachNames.length);
            assert(convObject.links[0].attachNames[0] == "C++ Pocket Reference.pdf");
        }

        unittest // clearSubject
        {
            writeln("Testing DriverConversationMongo.clearSubject");
            assert(clearSubject("RE: polompos") == "polompos");
            assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
            assert(clearSubject("Pok and something Re: things") == "Pok and something things");
        }

        unittest // setLinkDeleted
        {
            writeln("Testing DriverConversationMongo.setLinkDeleted");
            recreateTestDb();
            auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
            conv.setLinkDeleted(conv.links[0].emailDbId, true);
            conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
            assert(conv.links[0].deleted);
            conv.setLinkDeleted(conv.links[0].emailDbId, false);
            conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
            assert(!conv.links[0].deleted);
        }

        unittest // isOwnedBy
        {
            writeln("Testing DriverConversationMongo.isOwnedBy");
            recreateTestDb();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");

            auto conv = Conversation.getByReferences(user1.id,
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(Conversation.isOwnedBy(conv.id, user1.loginName));

            conv = Conversation.getByReferences(user2.id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.id.length);
            assert(Conversation.isOwnedBy(conv.id, user2.loginName));
        }

        unittest // searchEmails
        {
            import db.user;
            writeln("Testing DriverConversationMongo.searchEmails");
            recreateTestDb();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");
            auto convMongo = scoped!DriverConversationMongo();
            auto results = convMongo.searchEmails(["inicio de sesión"], user1.id);
            assert(results.length == 1);
            auto conv  = convMongo.get(results[0].convId);
            assert(conv.links[1].emailDbId == results[0].emailId);

            auto results2 = convMongo.searchEmails(["some"], user1.id);
            assert(results2.length == 2);
            foreach(ref result; results2)
            {
                conv = convMongo.get(result.convId);
                bool found = false;
                foreach(ref link; conv.links)
                {
                    if (link.emailDbId == result.emailId)
                    {
                        found = true;
                        break;
                    }
                }
                assert(found);
            }

            auto results3 = convMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z");
            assert(results3.length == 1);

            auto results4 = convMongo.searchEmails(["some"], user2.id, "2014-06-01T14:32:20Z",
                                                     "2014-08-01T00:00:00Z");
            assert(results4.length == 1);

            string startFixedDate = "2005-01-01T00:00:00Z";
            auto results5 = convMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                     "2018-12-12T00:00:00Z");
            assert(results5.length == 2);

            auto results6 = convMongo.searchEmails(["some"], user2.id, startFixedDate,
                                                     "2014-06-01T00:00:00Z");
            assert(results6.length == 1);
        }
    } // end version mongodriver
}

version(search_test)
{
    import db.conversation;
    import db.test_support;
    import db.user;
    import std.datetime;
    import std.stdio;
    import std.string;

    unittest  // search
    {
        writeln("Testing Conversation.search times");
        auto someUser = User.getFromLoginName("testuser");
        // last test on my laptop: about 40 msecs for 84 results with 33000 emails loaded
        StopWatch sw;
        sw.start();
        auto searchRes = Conversation.search(["testing"], someUser.id);
        sw.stop();
        writeln(format("Time to search with a result set of %s convs: %s msecs",
                searchRes.length, sw.peek.msecs));
        sw.reset();
    }
}
