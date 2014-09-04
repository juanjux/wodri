module db.tests.test_conversation;

version(db_test)
version(db_usetestdb)
{
    import db.test_support;
    import db.user;
    import db.conversation;
    import std.stdio;
    import vibe.data.bson;

    unittest // Conversation.hasLink
    {
        writeln("Testing Conversation.hasLink");
        recreateTestDb();
        auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        const emailDbId = conv.links[0].emailDbId;
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
        auto convId = conv.dbId;
        foreach(ref link; conv.receivedLinks)
            link.deleted = true;
        conv.store();
        conv = Conversation.get(convId);
        assert(conv.links[0].deleted);
        assert(conv.links[1].deleted);
    }

    unittest // Conversation.store
    {
        writeln("Testing Conversation.store");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        // update existing (id doesnt change)
        convs[0].addTag("newtag");
        string[] attachNames = ["one", "two"];
        convs[0].addLink("someMessageId", attachNames);
        auto oldDbId = convs[0].dbId;
        convs[0].store();

        auto convs2 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs2.length == 3);
        assert(convs2[0].dbId == oldDbId);
        assert(convs2[0].hasTag("inbox"));
        assert(convs2[0].hasTag("newtag"));
        assert(convs2[0].numTags == 2);
        assert(convs2[0].links[1].messageId == "someMessageId");
        assert(convs2[0].links[1].attachNames == attachNames);

        // create new (new dbId)
        convs2[0].dbId = BsonObjectID.generate().toString;
        convs2[0].store();
        auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs3.length == 4);

        bool found = false;
        foreach(conv; convs3)
        {
            if (conv.dbId == convs2[0].dbId)
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
}

version(search_test)
{
    unittest  // search
    {
        writeln("Testing Conversation.search times");
        // last test on my laptop: about 40 msecs for 84 results with 33000 emails loaded
        StopWatch sw;
        sw.start();
        auto searchRes = Email.search(["testing"], USER_TO_ID["testuser"]);
        sw.stop();
        writeln(format("Time to search with a result set of %s convs: %s msecs",
                searchRes.length, sw.peek.msecs));
        sw.reset();
    }


    unittest // get/docToObject
    {
        writeln("Testing DriverConversationMongo.get/docToObject");
        recreateTestDb();

        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length == 1);
        auto conv  = Conversation.get(convs[0].dbId);
        assert(conv !is null);
        assert(conv.lastDate.length); // this email date is set to NOW
        assert(conv.hasTag("inbox"));
        assert(conv.numTags == 1);
        assert(conv.links.length == 2);
        assert(conv.links[1].attachNames == ["google.png", "profilephoto.jpeg"]);
        assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
        assert(conv.links[0].deleted == false);

        convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        conv = Conversation.get(convs[1].dbId);
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

        conv = Conversation.get(convs[2].dbId);
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
        assert(convs2[0].dbId == convs[0].dbId);
        assert(convs2[1].dbId == convs[1].dbId);
        assert(convs2[0].links[0].deleted == false);
        assert(convs2[1].links[0].deleted == false);

        auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 1);
        assert(convs3.length == 1);
        assert(convs3[0].dbId == convs[2].dbId);

        auto convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
        assert(convs4[0].dbId == convs[0].dbId);
        assert(convs4[1].dbId == convs[1].dbId);
        assert(convs4[2].dbId == convs[2].dbId);
        assert(convs4[0].links[0].deleted == false);
        assert(convs4[1].links[0].deleted == false);
        assert(convs4[2].links[0].deleted == false);

        // check that it doesnt returns the deleted convs
        auto len1 = convs4.length;
        DriverConversationMongo.addTagDb(convs4[0].dbId, "deleted");
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
        assert(conv.dbId.length);
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
        assert(conv.dbId.length);
        assert(conv.lastDate == "2014-01-21T14:32:20Z");
        assert(conv.tagsArray == ["inbox"]);
        assert(conv.links.length == 1);
        assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
        assert(conv.links[0].emailDbId.length);
        assert(conv.links[0].deleted == false);

        DriverConversationMongo.addTagDb(conv.dbId, "deleted");
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
        assert(conv.dbId == conv2.dbId);

        auto conv3 = Conversation.getByEmailId("doesntexist");
        assert(conv3 is null);
    }


    unittest // addTagDb / removeTagDb
    {
        writeln("Testing DriversConversationMongo.addTagDb");
        recreateTestDb();
        auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
        assert(convs.length);
        auto dbId = convs[0].dbId;
        DriverConversationMongo.addTagDb(dbId, "testTag");
        auto conv = Conversation.get(dbId);
        assert(conv !is null);
        assert(conv.hasTag("testtag"));

        writeln("Testing DriverConversationMongo.removeTagDb");
        DriverConversationMongo.removeTagDb(dbId, "testTag");
        conv = Conversation.get(dbId);
        assert(!conv.hasTag("testtag"));
    }

    unittest // remove
    {
        writeln("Testing DriverConversationMongo.remove");
        recreateTestDb();
        auto convs = Conversation.getByTag( "inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 3);
        const id = convs[0].dbId;
        convs[0].remove();
        convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
        assert(convs.length == 2);
        foreach(conv; convs)
            assert(conv.dbId != id);
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
        auto convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
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
        assert(convObject.dbId     == convId);
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
        convId = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
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
        assert(convObject.dbId == convId);
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
        convId  = Conversation.addEmail(dbEmail, tagsToAdd, []).dbId;
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
        assert(convObject.dbId == convId);
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
        writeln("Testing Conversation.clearSubject");
        assert(clearSubject("RE: polompos") == "polompos");
        assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
        assert(clearSubject("Pok and something Re: things") == "Pok and something things");
    }

    unittest // Conversation.setEmailDeleted
    {
        writeln("Testing Conversation.setEmailDeleted");
        recreateTestDb();

        auto conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        conv.setEmailDeleted(conv.links[0].emailDbId, true);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(conv.links[0].deleted);
        conv.setEmailDeleted(conv.links[0].emailDbId, false);
        conv = Conversation.getByTag("inbox", USER_TO_ID["testuser"])[0];
        assert(!conv.links[0].deleted);
    }

    unittest // isOwnedBy
    {
        writeln("Testing Conversation.isOwnedBy");
        recreateTestDb();
        auto user1 = User.getFromAddress("testuser@testdatabase.com");
        auto user2 = User.getFromAddress("anotherUser@testdatabase.com");

        auto conv = Conversation.getByReferences(user1.id,
                ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(Conversation.isOwnedBy(conv.dbId, user1.loginName));

        conv = Conversation.getByReferences(user2.id,
            ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
        assert(conv !is null);
        assert(conv.dbId.length);
        assert(Conversation.isOwnedBy(conv.dbId, user2.loginName));
    }

    unittest // searchEmails
    {
        import db.user;
        writeln("Testing DriverEmailMongo.searchEmails");
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

    version(MongoDriver)
    {
        unittest // get/docToObject
        {
            writeln("Testing DriverConversationMongo.get/docToObject");
            recreateTestDb();

            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length == 1);
            auto conv  = Conversation.get(convs[0].dbId);
            assert(conv !is null);
            assert(conv.lastDate.length); // this email date is set to NOW
            assert(conv.hasTag("inbox"));
            assert(conv.numTags == 1);
            assert(conv.links.length == 2);
            assert(conv.links[1].attachNames == ["google.png", "profilephoto.jpeg"]);
            assert(conv.cleanSubject == ` some subject "and quotes" and noquotes`);
            assert(conv.links[0].deleted == false);

            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            conv = Conversation.get(convs[1].dbId);
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

            conv = Conversation.get(convs[2].dbId);
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
            assert(convs2[0].dbId == convs[0].dbId);
            assert(convs2[1].dbId == convs[1].dbId);
            assert(convs2[0].links[0].deleted == false);
            assert(convs2[1].links[0].deleted == false);

            auto convs3 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 2, 1);
            assert(convs3.length == 1);
            assert(convs3[0].dbId == convs[2].dbId);

            auto convs4 = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"], 1000, 0);
            assert(convs4[0].dbId == convs[0].dbId);
            assert(convs4[1].dbId == convs[1].dbId);
            assert(convs4[2].dbId == convs[2].dbId);
            assert(convs4[0].links[0].deleted == false);
            assert(convs4[1].links[0].deleted == false);
            assert(convs4[2].links[0].deleted == false);

            // check that it doesnt returns the deleted convs
            auto len1 = convs4.length;
            DriverConversationMongo.addTagDb(convs4[0].dbId, "deleted");
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
            assert(conv.dbId.length);
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
            assert(conv.dbId.length);
            assert(conv.lastDate == "2014-01-21T14:32:20Z");
            assert(conv.tagsArray == ["inbox"]);
            assert(conv.links.length == 1);
            assert(conv.links[0].messageId == "CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com");
            assert(conv.links[0].emailDbId.length);
            assert(conv.links[0].deleted == false);

            DriverConversationMongo.addTagDb(conv.dbId, "deleted");
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
            assert(conv.dbId == conv2.dbId);

            auto conv3 = Conversation.getByEmailId("doesntexist");
            assert(conv3 is null);
        }


        unittest // addTagDb / removeTagDb
        {
            writeln("Testing DriversConversationMongo.addTagDb");
            recreateTestDb();
            auto convs = Conversation.getByTag("inbox", USER_TO_ID["testuser"]);
            assert(convs.length);
            auto dbId = convs[0].dbId;
            DriverConversationMongo.addTagDb(dbId, "testTag");
            auto conv = Conversation.get(dbId);
            assert(conv !is null);
            assert(conv.hasTag("testtag"));

            writeln("Testing DriverConversationMongo.removeTagDb");
            DriverConversationMongo.removeTagDb(dbId, "testTag");
            conv = Conversation.get(dbId);
            assert(!conv.hasTag("testtag"));
        }

        unittest // remove
        {
            writeln("Testing DriverConversationMongo.remove");
            recreateTestDb();
            auto convs = Conversation.getByTag( "inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 3);
            const id = convs[0].dbId;
            convs[0].remove();
            convs = Conversation.getByTag("inbox", USER_TO_ID["anotherUser"]);
            assert(convs.length == 2);
            foreach(conv; convs)
                assert(conv.dbId != id);
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
            auto convId  = Conversation.addEmail(dbEmail.dbId, tagsToAdd, []).dbId;
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
            assert(convObject.dbId     == convId);
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
            convId = Conversation.addEmail(dbEmail.dbId, tagsToAdd, []).dbId;
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
            assert(convObject.dbId == convId);
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
            convId  = Conversation.addEmail(dbEmail.dbId, tagsToAdd, []).dbId;
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
            assert(convObject.dbId == convId);
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

        unittest // setEmailDeleted
        {
            writeln("Testing DriverConversationMongo.setEmailDeleted");
            recreateTestDb();
            auto convMongo = scoped!DriverMongo();
            auto conv = convMongo.getByTag("inbox", USER_TO_ID["testuser"])[0];
            conv.setEmailDeleted(conv.links[0].emailDbId, true);
            conv = convMongo.getByTag("inbox", USER_TO_ID["testuser"])[0];
            assert(conv.links[0].deleted);
            conv.setEmailDeleted(conv.links[0].emailDbId, false);
            conv = convMongo.getByTag("inbox", USER_TO_ID["testuser"])[0];
            assert(!conv.links[0].deleted);
        }

        unittest // isOwnedBy
        {
            writeln("Testing DriverEmailMongo.isOwnedBy");
            recreateTestDb();
            auto convMongo = scoped!DriverConversationMongo();
            auto user1 = User.getFromAddress("testuser@testdatabase.com");
            auto user2 = User.getFromAddress("anotherUser@testdatabase.com");

            auto conv = convMongo.getByReferences(user1.id,
                    ["AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.dbId.length);
            assert(convMongo.isOwnedBy(conv.dbId, user1.loginName));

            conv = convMongo.getByReferences(user2.id,
                ["CAGA-+RThgLfRakYHjW5Egq9xkctTwwqukHgUKxs1y_yoDZCM8w@mail.gmail.com"]);
            assert(conv !is null);
            assert(conv.dbId.length);
            assert(convMongo.isOwnedBy(conv.dbId, user2.loginName));
        }

        unittest // searchEmails
        {
            import db.user;
            writeln("Testing DriverEmailMongo.searchEmails");
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
