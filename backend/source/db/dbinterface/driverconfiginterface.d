module db.dbinterface.driverconfiginterface;

import db.config: RetrieverConfig;

interface DriverConfigInterface
{
    RetrieverConfig getConfig();

    void insertTestSettings();
}
