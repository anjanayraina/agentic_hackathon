// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title FieldUtils
 * @notice Provides utility functions related to map field types.
 */
library FieldUtils {
    enum FieldType { Normal, Mountain, River }

    /**
     * @notice Determines the field type for a given coordinate.
     * @dev Uses a pseudo–random (deterministic) calculation based on (x,y).
     */
    function getFieldType(uint x, uint y) internal pure returns (FieldType) {
        uint rand = uint(keccak256(abi.encodePacked(x, y))) % 100;
        if (rand < 10) {
            return FieldType.Mountain;
        } else if (rand < 20) {
            return FieldType.River;
        } else {
            return FieldType.Normal;
        }
    }
}
