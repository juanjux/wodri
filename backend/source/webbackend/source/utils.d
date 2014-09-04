module webbackend.utils;

import dauth;
import db.config: getConfig;
import db.user: User;
import vibe.http.server;
import std.functional: toDelegate;


bool checkAuth(string user, string password)
{
    const dbUser = User.getFromLoginName(user);
    return dbUser is null ? false
                          : isSameHash(toPassword(password.dup), 
                                       parseHash(dbUser.loginHash));
}
