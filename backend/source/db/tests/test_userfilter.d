module db.tests.test_userfilter;


version(db_test)
version(db_usetestdb)
{
    import db.config;
    import db.email;
    import db.test_support;
    import db.userfilter;
    import retriever.incomingemail;
    import std.algorithm;
    import std.path;
    import std.stdio;
    import std.typecons;

    unittest
    {
        recreateTestDb();

        writeln("Testing UserFilter matching");
        auto config = getConfig();
        auto testDir = buildPath(config.mainDir, "backend", "test");
        auto testEmailDir = buildPath(testDir, "testemails");
        string[] tagsToAdd;
        string[] tagsToRemove;

        // this will change the outer "tagsToAdd/tagsToRemove" dicts
        Email reInstance(Match match, Action action)
        {
            auto inEmail = scoped!IncomingEmail();
            inEmail.loadFromFile(buildPath(testEmailDir, "with_2megs_attachment"),
                                 buildPath(testDir, "attachments"));
            auto dbEmail  = new Email(inEmail);
            dbEmail.destinationAddress = "foo@foo.com";
            dbEmail.userId = "fakeuserid";
            // a little kludge so I dont have to store this email to get an id
            dbEmail.id = Email.messageIdToDbId(dbEmail.messageId);
            auto filter   = scoped!UserFilter(match, action);
            tagsToAdd = [];
            tagsToRemove = [];
            filter.apply(dbEmail, tagsToAdd, tagsToRemove);
            return dbEmail;
        }

        // Match the From, set unread to false
        Match match; match.headerMatches["from"] = "someuser@somedomain.com";
        Action action; action.markAsRead = true;
        reInstance(match, action);
        assert(countUntil(tagsToAdd, "unread") == -1);
        assert(countUntil(tagsToRemove, "unread") != -1);

        // Fail to match the From
        Match match2; match2.headerMatches["from"] = "foo@foo.com";
        Action action2; action2.markAsRead = true;
        reInstance(match2, action2);
        assert(countUntil(tagsToAdd, "unread") == -1);
        assert(countUntil(tagsToRemove, "unread") == -1);

        // Match the withAttachment, set inbox to false
        Match match3; match3.withAttachment = true;
        Action action3; action3.noInbox = true;
        reInstance(match3, action3);
        assert(countUntil(tagsToAdd, "inbox") == -1);
        assert(countUntil(tagsToRemove, "inbox") != -1);

        // Match the withHtml, set deleted to true
        Match match4; match4.withHtml = true;
        Action action4; action4.deleteIt = true;
        reInstance(match4, action4);
        assert(countUntil(tagsToAdd, "deleted") != -1);
        assert(countUntil(tagsToRemove, "deleted") == -1);

        // Negative match on body
        Match match5; match5.bodyMatches = ["nomatch_atall"];
        Action action5; action5.deleteIt = true;
        reInstance(match5, action5);
        assert(countUntil(tagsToAdd, "deleted") == -1);
        assert(countUntil(tagsToRemove, "deleted") == -1);

        //Match SizeGreaterThan, set tag
        Match match6;
        match6.totalSizeType = SizeRuleType.GreaterThan;
        match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
        Action action6; action6.addTags = ["testtag1", "testtag2"];
        reInstance(match6, action6);
        assert(countUntil(tagsToAdd, "testtag1") != -1);
        assert(countUntil(tagsToRemove, "testtag1") == -1);
        assert(countUntil(tagsToAdd, "testtag2") != -1);
        assert(countUntil(tagsToRemove, "testtag2") == -1);

        //Dont match SizeGreaterThan, set tag
        Match match7;
        match7.totalSizeType = SizeRuleType.GreaterThan;
        match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
        Action action7; action7.addTags = ["testtag1", "testtag2"];
        reInstance(match7, action7);
        assert(countUntil(tagsToAdd, "testtag1") == -1);
        assert(countUntil(tagsToRemove, "testtag1") == -1);
        assert(countUntil(tagsToAdd, "testtag2") == -1);
        assert(countUntil(tagsToRemove, "testtag2") == -1);

        // Match SizeSmallerThan, set forward
        Match match8;
        match8.totalSizeType = SizeRuleType.SmallerThan;
        match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
        Action action8;
        action8.forwardTo = ["juanjux@yahoo.es"];
        auto email3 = reInstance(match8, action8);
        assert(email3.forwardedTo[0] == "juanjux@yahoo.es");

        // Dont match SizeSmallerTham
        Match match9;
        match9.totalSizeType = SizeRuleType.SmallerThan;
        match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
        Action action9;
        action9.forwardTo = ["juanjux@yahoo.es"];
        auto email4 = reInstance(match9, action9);
        assert(!email4.forwardedTo.length);
    }

    version(MongoDriver)
    {
        unittest // getByAddress
        {
            writeln("Testing DriverUserFilterMongo.getByAddress");
            auto filters = UserFilter.getByAddress("testuser@testdatabase.com");
            assert(filters.length == 1);
            assert(!filters[0].match.withAttachment);
            assert(!filters[0].match.withHtml);
            assert(filters[0].match.totalSizeType        == SizeRuleType.GreaterThan);
            assert(filters[0].match.totalSizeValue       == 100485760);
            assert(filters[0].match.bodyMatches.length   == 1);
            assert(filters[0].match.bodyMatches[0]       == "XXXBODYMATCHXXX");
            assert(filters[0].match.headerMatches.length == 1);
            assert("From" in filters[0].match.headerMatches);
            assert(filters[0].match.headerMatches["From"] == "juanjo@juanjoalvarez.net");
            assert(!filters[0].action.forwardTo.length);
            assert(!filters[0].action.noInbox);
            assert(filters[0].action.markAsRead);
            assert(!filters[0].action.deleteIt);
            assert(filters[0].action.neverSpam);
            assert(!filters[0].action.setSpam);
            assert(filters[0].action.addTags == ["testtag1", "testtag2"]);
            auto filters2 = UserFilter.getByAddress("anotherUser@anotherdomain.com");
            assert(filters2[0].action.addTags == ["testtag3", "testtag4"]);
            auto newfilters = UserFilter.getByAddress("anotherUser@testdatabase.com");
            assert(filters2[0].action.addTags == newfilters[0].action.addTags);
        }
    }
}
