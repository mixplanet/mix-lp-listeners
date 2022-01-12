pragma solidity ^0.5.6;

import "./klaytn-contracts/ownership/Ownable.sol";
import "./klaytn-contracts/math/SafeMath.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/ITurntableLPListeners.sol";
import "./interfaces/IMixEmitter.sol";
import "./interfaces/IMix.sol";
import "./interfaces/ITurntables.sol";
import "./interfaces/ILP.sol";
import "./interfaces/IRewardToken.sol";

contract TurntableLPListeners is Ownable, ITurntableLPListeners {
    using SafeMath for uint256;
    using SignedSafeMath for int256;

    IMixEmitter public mixEmitter;
    IMix public mix;
    uint256 public pid;
    ITurntables public turntables;
    ILP public lp;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;

    constructor(
        IMixEmitter _mixEmitter,
        uint256 _pid,
        ITurntables _turntables,
        ILP _lp
    ) public {
        mixEmitter = _mixEmitter;
        mix = _mixEmitter.mix();
        pid = _pid;
        turntables = _turntables;
        lp = _lp;
        rewardTokens.push(address(mix));
    }

    function addRewardToken(address token) external onlyOwner {
        require(!isRewardToken[token]);
        rewardTokens.push(token);
        isRewardToken[token] = true;
    }

    function removeRewardToken(address token) external onlyOwner {
        uint256 length = rewardTokens.length;
        require(isRewardToken[token]);
        for (uint256 i = 0; i < length; i = i.add(1)) {
            if (rewardTokens[i] == token) {
                rewardTokens[i] = rewardTokens[length.sub(1)];
                rewardTokens.length -= 1;
                delete isRewardToken[token];
                break;
            }
        }
    }

    uint256 public turntableFee = 3000;

    uint256 public totalShares = 0;
    mapping(uint256 => uint256) public turntableShares;
    mapping(uint256 => mapping(address => uint256)) public shares;

    uint256 private constant pointsMultiplier = 2**128;

    mapping(address => uint256) private currentBalances;
    mapping(address => uint256) private pointsPerShares;
    mapping(uint256 => mapping(address => mapping(address => int256))) private pointsCorrections;
    mapping(uint256 => mapping(address => mapping(address => uint256))) private claimed;

    function setTurntableFee(uint256 fee) external onlyOwner {
        require(fee < 1e4);
        turntableFee = fee;
        emit SetTurntableFee(fee);
    }

    function updateBalance() private {
        if (totalShares > 0) {
            mixEmitter.updatePool(pid);
            lp.claimReward();
            uint256 length = rewardTokens.length;
            for (uint256 i = 0; i < length; i = i.add(1)) {
                address rewardToken = rewardTokens[i];
                uint256 balance = IRewardToken(rewardToken).balanceOf(address(this));
                uint256 value = balance.sub(currentBalances[rewardToken]);
                if (value > 0) {
                    pointsPerShares[rewardToken] = pointsPerShares[rewardToken].add(value.mul(pointsMultiplier).div(totalShares));
                    emit Distribute(msg.sender, value);
                }
                currentBalances[rewardToken] = balance;
            }
        } else {
            mixEmitter.updatePool(pid);
            uint256 balance = mix.balanceOf(address(this));
            uint256 value = balance.sub(currentBalances[address(mix)]);
            if (value > 0) mix.burn(value);
        }
    }

    function claimedOf(uint256 turntableId, address owner, address token) public view returns (uint256) {
        return claimed[turntableId][owner][token];
    }

    function accumulativeOf(uint256 turntableId, address owner, address token) public view returns (uint256) {
        uint256 _pointsPerShare = pointsPerShares[token];
        if (totalShares > 0) {
            uint256 balance = token == address(mix) ? mixEmitter.pendingMix(pid).add(mix.balanceOf(address(this))) : IRewardToken(token).balanceOf(address(this));
            uint256 value = balance.sub(currentBalances[token]);
            if (value > 0) {
                _pointsPerShare = _pointsPerShare.add(value.mul(pointsMultiplier).div(totalShares));
            }
            return
                uint256(
                    int256(_pointsPerShare.mul(shares[turntableId][owner])).add(pointsCorrections[turntableId][owner][token])
                ).div(pointsMultiplier);
        }
        return 0;
    }

    function claimableOf(uint256 turntableId, address owner, address token) external view returns (uint256) {
        return
            accumulativeOf(turntableId, owner, token).sub(claimed[turntableId][owner][token]).mul(uint256(1e4).sub(turntableFee)).div(
                1e4
            );
    }

    function _accumulativeOf(uint256 turntableId, address owner, address token) private view returns (uint256) {
        return
            uint256(int256(pointsPerShares[token].mul(shares[turntableId][owner])).add(pointsCorrections[turntableId][owner][token]))
                .div(pointsMultiplier);
    }

    function _claimableOf(uint256 turntableId, address owner, address token) private view returns (uint256) {
        return _accumulativeOf(turntableId, owner, token).sub(claimed[turntableId][owner][token]);
    }

    function claim(uint256[] calldata turntableIds, address token) external {
        updateBalance();

        uint256 length = turntableIds.length;
        uint256 totalClaimable = 0;

        for (uint256 i = 0; i < length; i = i + 1) {
            uint256 turntableId = turntableIds[i];
            uint256 claimable = _claimableOf(turntableId, msg.sender, token);
            if (claimable > 0) {
                claimed[turntableId][msg.sender][token] = claimed[turntableId][msg.sender][token].add(claimable);
                emit Claim(turntableId, msg.sender, token, claimable);

                if(token == address(mix)) {
                    uint256 fee = claimable.mul(turntableFee).div(1e4);
                    if (turntables.exists(turntableId)) {
                        mix.transfer(turntables.ownerOf(turntableId), fee);
                    } else {
                        mix.burn(fee);
                    }
                    mix.transfer(msg.sender, claimable.sub(fee));
                } else {
                    IRewardToken(token).transfer(msg.sender, claimable);
                }

                totalClaimable = totalClaimable.add(claimable);
            }
        }
        currentBalances[token] = currentBalances[token].sub(totalClaimable);
    }

    function listen(uint256 turntableId, uint256 amount) external {
        require(turntables.exists(turntableId));
        updateBalance();

        totalShares = totalShares.add(amount);
        shares[turntableId][msg.sender] = shares[turntableId][msg.sender].add(amount);
        turntableShares[turntableId] = turntableShares[turntableId].add(amount);

        uint256 length = rewardTokens.length;
        for (uint256 i = 0; i < length; i = i.add(1)) {
            address rewardToken = rewardTokens[i];
            pointsCorrections[turntableId][msg.sender][rewardToken] = pointsCorrections[turntableId][msg.sender][rewardToken].sub(
                int256(pointsPerShares[rewardToken].mul(amount))
            );
        }

        lp.transferFrom(msg.sender, address(this), amount);
        emit Listen(turntableId, msg.sender, amount);
    }

    function unlisten(uint256 turntableId, uint256 amount) external {
        updateBalance();

        totalShares = totalShares.sub(amount);
        shares[turntableId][msg.sender] = shares[turntableId][msg.sender].sub(amount);
        turntableShares[turntableId] = turntableShares[turntableId].sub(amount);

        uint256 length = rewardTokens.length;
        for (uint256 i = 0; i < length; i = i.add(1)) {
            address rewardToken = rewardTokens[i];
            pointsCorrections[turntableId][msg.sender][rewardToken] = pointsCorrections[turntableId][msg.sender][rewardToken].add(
                int256(pointsPerShares[rewardToken].mul(amount))
            );
        }

        lp.transfer(msg.sender, amount);
        emit Unlisten(turntableId, msg.sender, amount);
    }
}
