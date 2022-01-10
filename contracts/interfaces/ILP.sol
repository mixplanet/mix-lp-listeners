pragma solidity ^0.5.6;

interface ILP {    
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function claimReward() external;
}
