return {
    -- How far from your ped a rack may be put down, metres. The ghost turns red past it and the
    -- server refuses it (with a little slack for the ped shuffling while you confirm).
    Range = 4.0,

    -- Smallest gap between two racks' origins, metres. Racks whose boxes overlap are refused
    -- anyway; this only stops racks being stacked on exactly the same spot.
    MinDistance = 0.3,

    -- How steep a surface still counts. Floor/table racks need a surface whose normal points at
    -- least this much up (1.0 = perfectly flat); wall racks need a wall whose normal is within this
    -- much of horizontal (0.0 = perfectly vertical).
    FloorNormalZ = 0.7,
    WallNormalZ = 0.3,
}
