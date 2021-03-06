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
module db.mongo.driveruserfiltermongo;


version(MongoDriver)
{
import db.dbinterface.driveruserfilterinterface;
import db.mongo.mongo;
import db.userfilter: UserFilter, Match, Action, SizeRuleType;
import vibe.data.bson;
import vibe.core.log;
import std.string;

final class DriverUserfilterMongo : DriverUserfilterInterface
{
// this override doesnt detect getByAddress as override if uncommented, probably compiler
// bug: FIXME: try with laters versions or open bug report:
//override:
    UserFilter[] getByAddress(in string address)
    {
        UserFilter[] res;
        const userRuleFindJson = parseJsonString(
                format(`{"destinationAccounts": {"$in": ["%s"]}}`, address)
        );
        auto userRuleCursor = collection("userrule").find(userRuleFindJson);

        foreach(ref Bson rule; userRuleCursor)
        {
            Match match;
            Action action;
            try
            {
                immutable sizeRule = bsonStr(rule.match_sizeRuleType);
                switch(sizeRule)
                {
                    case "None":
                        match.totalSizeType = SizeRuleType.None; break;
                    case "SmallerThan":
                        match.totalSizeType = SizeRuleType.SmallerThan; break;
                    case "GreaterThan":
                        match.totalSizeType = SizeRuleType.GreaterThan; break;
                    default:
                        auto err = "SizeRuleType must be one of None, GreaterThan or SmallerThan";
                        logError(err);
                        throw new Exception(err);
                }

                match.withAttachment = bsonBool    (rule.match_withAttachment);
                match.withHtml       = bsonBool    (rule.match_withHtml);
                match.totalSizeValue = to!ulong    (bsonNumber(rule.match_totalSizeValue));
                match.bodyMatches    = bsonStrArray(rule.match_bodyText);
                match.headerMatches  = bsonStrHash (rule.match_headers);

                action.noInbox       = bsonBool    (rule.action_noInbox);
                action.markAsRead    = bsonBool    (rule.action_markAsRead);
                action.deleteIt      = bsonBool    (rule.action_delete);
                action.neverSpam     = bsonBool    (rule.action_neverSpam);
                action.setSpam       = bsonBool    (rule.action_setSpam);
                action.forwardTo     = bsonStrArray(rule.action_forwardTo);
                action.addTags       = bsonStrArray(rule.action_addTags);

                res ~= new UserFilter(match, action);
            } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
        }
        return res;
    }
}
} // end version(MongoDriver)
