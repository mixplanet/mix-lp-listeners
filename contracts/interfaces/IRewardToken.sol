pragma solidity ^0.5.6;

interface IRewardToken {    
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
